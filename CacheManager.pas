unit CacheManager;

interface

uses
  System.Rtti,
  System.TypInfo,
  System.SysUtils,
  System.SyncObjs,
  System.TimeSpan,
  System.Diagnostics,
  System.Generics.Defaults,
  System.Generics.Collections;

type
  ECacheException = class(Exception);

  //
  // Record used to store the cache key-value
  // information.
  //
  PValueNode = ^TValueNode;

  TValueNode = record
    strict private
      FValue: TValue;
      FStopwatch: TStopwatch;
      FExpiresInMillis: Int64;
      FKey: String;
    private
      Next: PValueNode;
      Previous: PValueNode;
    strict private
      function GetElapsedMillis(): Int64;
      procedure CheckSupportedTypeInfo(const TypeInfo: PTypeInfo);
    public
      function AsValue<V>(): V;
      procedure Initialize(const Key: String;
                           const Value: TValue;
                           const ExpiresInMillis: Int64);
    public
      property ExpiresInMillis: Int64 read FExpiresInMillis;
      property ElapsedMillis: Int64 read GetElapsedMillis;
      property Key: String read FKey;
    end;

  //
  // Enumeration helper types
  //
  TCacheValue = packed record
    strict private
      FValueNode: PValueNode;
    public
      function AsValue<V>(): V;
  private
    function GetValueNodePointer: PValueNode;
    public
      class function From(const ValueNode: PValueNode): TCacheValue; static;
    end;

  TCachePair = record
    strict private
      FKey: String;
      FValue: TCacheValue;
    public
      property Key: String read FKey;
      property Value: TCacheValue read FValue;
    public
      class function WithPair(const Pair: TPair<String, PValueNode>): TCachePair; static;
    end;

  //
  // TCacheTable implements a LRU cache mechanism using TDoublyLinkedList
  // along with TDictionary to make O(1) operations while mainting the
  // capacity correct.
  //
  TCacheTable = class(TEnumerable<TCachePair>)
    strict private type
      //
      // This class does not lock anything. It should be used internally
      // with the IReadWriteSync synchronization blocks.
      //
      TDoublyLinkedList = class
        strict private
          FHead, FTail: PValueNode;
        private
          procedure Clear();
          procedure MoveToFront(const ValueNode: PValueNode);
          procedure AddToFront(const ValueNode: PValueNode);
          procedure RemoveNode(const ValueNode: PValueNode);
          function RemoveEldest(out Key: String): Boolean;
        public
          constructor Create();
          destructor Destroy(); override;
        end;
    private type
      TCachePairEnumerator = class sealed(TEnumerator<TCachePair>)
        private
          FOwner: TCacheTable;
          FEnumerator: TEnumerator<TPair<String, PValueNode>>;
          function GetCurrent(): TCachePair;
        protected
          function DoGetCurrent(): TCachePair; override;
          function DoMoveNext(): Boolean; override;
        public
          constructor Create(Owner: TCacheTable);
          destructor Destroy(); override;
        public
          property Current: TCachePair read GetCurrent;
          function MoveNext: Boolean;
      end;
    private
      FRWSync: IReadWriteSync;
      FDefaultExpiresInMillis: Int64;
      FCacheDictionary: TDictionary<String, PValueNode>;
      FCacheLinkedList: TDoublyLinkedList;
      FCapacity: Integer;
    private
      //
      // Unsafe here means it interacts with internal structures
      // without locking.
      //
      procedure HandleUnsafePut(const ValueNode: PValueNode);
      procedure HandleUnsafeRemove(var ValueNode: PValueNode);
    protected
      function GetCount(): Integer;
      function DoGetEnumerator(): TEnumerator<TCachePair>; override;
    public
      procedure EvictAll();
      procedure Evict(const Key: String);
      procedure Put<V>(const Key: String; const Value: V); overload;
      procedure Put<V>(const Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      function GetOrMiss<V>(const Key: String; out Value: V): Boolean;
    public
      constructor Create(const Capacity: Integer;
                         const DefaultExpiresInMillis: Int64 = -1);
      destructor Destroy(); override;
    public
      property Count: Integer read GetCount;
    end;

  TCacheManager = class sealed
    strict private
      class var GlobalCacheTable: TCacheTable;
    public
      class procedure EvictAll();
      class procedure Evict(const Key: String);
      class procedure Put<V>(const Key: String; const Value: V); overload;
      class procedure Put<V>(const Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      class function GetOrMiss<V>(const Key: String; out Value: V): Boolean; overload;
    public
      class constructor Initialize();
      class destructor Unitialize();
    end;

implementation

{$Region 'TCacheTable' }

constructor TCacheTable.Create(
  const Capacity: Integer;
  const DefaultExpiresInMillis: Int64 = -1);
begin
  FCapacity := Capacity;
  Assert(FCapacity >= 1, 'Capacity must be equals or greater than 1.');

  FDefaultExpiresInMillis := DefaultExpiresInMillis;
  FRWSync := TMultiReadExclusiveWriteSynchronizer.Create();
  FCacheLinkedList := TDoublyLinkedList.Create();
  FCacheDictionary := TDictionary<String, PValueNode>.Create(FCapacity + 1);
end;

procedure TCacheTable.Put<V>(
  const Key: String;
  const Value: V);
begin
  Put(Key, -1, Value);
end;

procedure TCacheTable.Put<V>(
  const Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
var
  lElderKey: String;
  lValueNode: PValueNode;
  lExpiresInMillis: Integer;
  lValue: TValue;
begin
  lValueNode := nil;
  lExpiresInMillis := FDefaultExpiresInMillis;

  if ExpiresInMillis <> -1 then
    lExpiresInMillis := ExpiresInMillis;

  FRWSync.BeginWrite();
  try
    //
    // If i'm replacing the value, the previous node should
    // be destroyed appropriately.
    //
    if FCacheDictionary.TryGetValue(Key, lValueNode) then
      HandleUnsafeRemove(lValueNode);

    lValue := TValue.From<V>(Value);

    New(lValueNode);
    lValueNode.Initialize(Key, lValue, lExpiresInMillis);
    HandleUnsafePut(lValueNode);

    if FCacheDictionary.Count > FCapacity then
    begin
      if FCacheLinkedList.RemoveEldest(lElderKey) then
        FCacheDictionary.Remove(lElderKey);
    end;
  finally
    FRWSync.EndWrite();
  end;
end;

function TCacheTable.GetOrMiss<V>(
  const Key: String;
  out Value: V): Boolean;
var
  lValueNode: PValueNode;
begin
  Result := False;
  FRWSync.BeginRead();
  try
    if not FCacheDictionary.TryGetValue(Key, lValueNode) then
    begin
      Value := Default(V);
      Result := False;
      Exit;
    end;

    if lValueNode.ElapsedMillis < lValueNode.ExpiresInMillis then
    begin
      FCacheLinkedList.MoveToFront(lValueNode);
      Value := lValueNode.AsValue<V>();
      Result := True;
      Exit;
    end;
  finally
    FRWSync.EndRead();
  end;

  FRWSync.BeginWrite();
  try
    if FCacheDictionary.TryGetValue(Key, lValueNode) then
    begin
      FCacheLinkedList.RemoveNode(lValueNode);
      FCacheDictionary.Remove(Key);
      Result := False;
      Exit;
    end;
  finally
    FRWSync.EndWrite();
  end;
end;

procedure TCacheTable.Evict(const Key: String);
var
  lValueNode: PValueNode;
begin
  FRWSync.BeginWrite();
  try
    if FCacheDictionary.TryGetValue(Key, lValueNode) then
      HandleUnsafeRemove(lValueNode);
  finally
    FRWSync.EndWrite();
  end;
end;

procedure TCacheTable.EvictAll();
begin
  FRWSync.BeginWrite();
  try
    FCacheLinkedList.Clear();
    FCacheDictionary.Clear();
  finally
    FRWSync.EndWrite();
  end;
end;

function TCacheTable.GetCount(): Integer;
begin
  FRWSync.BeginRead();
  try
    Result := FCacheDictionary.Count;
  finally
    FRWSync.EndRead();
  end;
end;

function TCacheTable.DoGetEnumerator(): TEnumerator<TCachePair>;
begin
  Result := TCachePairEnumerator.Create(Self);
end;

procedure TCacheTable.HandleUnsafePut(const ValueNode: PValueNode);
begin
  FCacheDictionary.Add(ValueNode.Key, ValueNode);
  FCacheLinkedList.AddToFront(ValueNode);
end;

procedure TCacheTable.HandleUnsafeRemove(var ValueNode: PValueNode);
begin
  FCacheDictionary.Remove(ValueNode.Key);
  FCacheLinkedList.RemoveNode(ValueNode);
  Dispose(ValueNode);
  ValueNode := nil;
end;

destructor TCacheTable.Destroy();
begin
  EvictAll();
  FCacheDictionary.Free();
  FCacheLinkedList.Free();
  FRWSync := nil;
  inherited;
end;

{$EndRegion 'TCacheTable' }

{$Region 'TValueNode' }

procedure TValueNode.Initialize(
  const Key: String;
  const Value: TValue;
  const ExpiresInMillis: Int64);
begin
  FKey := Key;
  FValue := Value;

  FExpiresInMillis := ExpiresInMillis;
  if FExpiresInMillis <> -1 then
    FStopwatch := TStopwatch.StartNew();

  Next := nil;
  Previous := nil;
end;

function TValueNode.AsValue<V>(): V;
var
  lValue: TValue;
  lVTypeInfo: PTypeInfo;
begin
  lVTypeInfo := TypeInfo(V);

  CheckSupportedTypeInfo(lVTypeInfo);

  lValue := FValue;

  if (FValue.IsEmpty) or (lVTypeInfo = nil) then
  begin
    Result := Default(V);
    Exit;
  end;

  if lVTypeInfo <> FValue.TypeInfo then
    lValue := FValue.Cast<V>(True);

  Result := lValue.AsType<V>();
end;

function TValueNode.GetElapsedMillis(): Int64;
begin
  Result := FStopwatch.ElapsedMilliseconds;
end;

procedure TValueNode.CheckSupportedTypeInfo(
  const TypeInfo: PTypeInfo);
begin
  if TypeInfo.Kind in [tkClass, tkInterface, tkClassRef, tkMRecord] then
    raise ECacheException.CreateFmt('Unsupported cache value : %s.', [String(TypeInfo.Name)]);
end;

{$EndRegion 'TCacheTable.TValueNode' }

{$Region 'TCacheManager' }

class constructor TCacheManager.Initialize();
const
  DEF_CAPACITY   = 128;
  DEF_EXPIRES_IN = 1000 * 60 * 5;
begin
  GlobalCacheTable := TCacheTable.Create(DEF_CAPACITY, DEF_EXPIRES_IN);
end;

class procedure TCacheManager.EvictAll();
begin
  GlobalCacheTable.EvictAll();
end;

class procedure TCacheManager.Evict(
  const Key: String);
begin
  GlobalCacheTable.Evict(Key);
end;

class function TCacheManager.GetOrMiss<V>(
  const Key: String;
  out Value: V): Boolean;
begin
  Result := GlobalCacheTable.GetOrMiss<V>(Key, Value);
end;

class procedure TCacheManager.Put<V>(
  const Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
begin
  GlobalCacheTable.Put<V>(Key, ExpiresInMillis, Value);
end;

class procedure TCacheManager.Put<V>(
  const Key: String;
  const Value: V);
begin
  GlobalCacheTable.Put<V>(Key, Value);
end;

class destructor TCacheManager.Unitialize();
begin
  FreeAndNil(GlobalCacheTable);
end;

{$EndRegion 'TCacheManager' }

{$Region 'TCacheTable.TDoublyLinkedList' }

constructor TCacheTable.TDoublyLinkedList.Create();
begin
  FHead := nil; FTail := nil;
end;

procedure TCacheTable.TDoublyLinkedList.AddToFront(
  const ValueNode: PValueNode);
begin
  ValueNode.Previous := nil;
  ValueNode.Next := FHead;

  if FHead <> nil then
    FHead.Previous := ValueNode;

  FHead := ValueNode;

  if FTail = nil then
    FTail := ValueNode;
end;

procedure TCacheTable.TDoublyLinkedList.RemoveNode(
  const ValueNode: PValueNode);
begin
  if ValueNode.Previous <> nil then
    ValueNode.Previous.Next := ValueNode.Next
  else
    FHead := ValueNode.Next;

  if ValueNode.Next <> nil then
    ValueNode.Next.Previous := ValueNode.Previous
  else
    FTail := ValueNode.Previous;
end;

procedure TCacheTable.TDoublyLinkedList.MoveToFront(
  const ValueNode: PValueNode);
begin
  if ValueNode = FHead then
    Exit;

  RemoveNode(ValueNode);
  AddToFront(ValueNode);
end;

function TCacheTable.TDoublyLinkedList.RemoveEldest(
  out Key: String): Boolean;
var
  lValueNode: PValueNode;
begin
  Key := EmptyStr;

  if FTail = nil then
  begin
    Result := False;
    Exit;
  end;

  lValueNode := FTail;
  RemoveNode(lValueNode);

  Key := lValueNode.Key;
  Dispose(lValueNode);
  Result := True;
end;

procedure TCacheTable.TDoublyLinkedList.Clear();
var
  lNext: PValueNode;
  lCurrNode: PValueNode;
begin
  lCurrNode := FHead;

  while lCurrNode <> nil do
  begin
    lNext := lCurrNode^.Next;
    Dispose(lCurrNode);
    lCurrNode := lNext;
  end;

  FHead := nil; FTail := nil;
end;

destructor TCacheTable.TDoublyLinkedList.Destroy();
begin
  Clear();
  inherited;
end;

{$EndRegion 'TCacheTable.TDoublyLinkedList'}

{$Region 'TCacheTable.TCachePairEnumerator' }

constructor TCacheTable.TCachePairEnumerator.Create(Owner: TCacheTable);
begin
  FOwner := Owner;
  FOwner.FRWSync.BeginRead();
  FEnumerator := FOwner.FCacheDictionary.GetEnumerator();
end;

function TCacheTable.TCachePairEnumerator.DoGetCurrent(): TCachePair;
begin
  Result := GetCurrent();
end;

function TCacheTable.TCachePairEnumerator.DoMoveNext(): Boolean;
begin
  Result := MoveNext();
end;

function TCacheTable.TCachePairEnumerator.GetCurrent(): TCachePair;
begin
  Result := TCachePair.WithPair(FEnumerator.Current);
end;

function TCacheTable.TCachePairEnumerator.MoveNext(): Boolean;
begin
  Result := FEnumerator.MoveNext();
end;

destructor TCacheTable.TCachePairEnumerator.Destroy();
begin
  FEnumerator.Free();
  FOwner.FRWSync.EndRead();
  inherited;
end;

{$EndRegion 'TCacheTable.TCachePairEnumerator' }

{$Region 'TCachePair' }

class function TCachePair.WithPair(
  const Pair: TPair<String, PValueNode>): TCachePair;
begin
  Result.FKey := Pair.Key;
  Result.FValue := TCacheValue.From(Pair.Value);
end;

{$EndRegion 'TCachePair' }

{$Region 'TCacheValue' }

class function TCacheValue.From(
  const ValueNode: PValueNode): TCacheValue;
begin
  Result.FValueNode := ValueNode;
end;

function TCacheValue.AsValue<V>: V;
begin
  Result := GetValueNodePointer().AsValue<V>();
end;

function TCacheValue.GetValueNodePointer(): PValueNode;
begin
  Result := FValueNode;
end;

{$EndRegion 'TCacheValue' }

end.
