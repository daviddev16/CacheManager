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
  TCacheTable = class
    private type
      TCacheValue = class
        private
          FValue: TValue;
          FStopwatch: TStopwatch;
          FExpiresInMillis: Int64;
          FOwnsValues: Boolean;
        private
          function GetElapsedMillis(): Int64;
        public
          function ResolveValue<V>(): V;
          constructor Create(const Value: TValue;
                             const ExpiresInMillis: Int64;
                             const OwnsValues: Boolean);
          destructor Destroy(); override;
        public
          property ExpiresInMillis: Int64 read FExpiresInMillis;
          property ElapsedMillis: Int64 read GetElapsedMillis;
        end;
    strict private
      FRWSync: IReadWriteSync;
      FOwnsValues: Boolean;
      FDefaultExpiresInMillis: Int64;
      FCacheDictionary: TDictionary<String, TCacheValue>;
    public
      procedure Evict(const Key: String);
      procedure Put<V>(const Key: String; const Value: V); overload;
      procedure Put<V>(const Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      function GetOrMiss<V>(const Key: String; out Value: V): Boolean;
      procedure Invalidate();
    public
      constructor Create(const OwnsValues: Boolean;
                         const DefaultExpiresInMillis: Int64 = -1);
      destructor Destroy(); override;
    end;

  TSectionCacheTable = class
    private const
      AVAILABLE_SECTIONS = 32;
    strict private
      FSections: TArray<TCacheTable>;
      FSectionsCount: Integer;
    private
      function GetSectionIndex(const Section: String): Integer; inline;
    public // general cache section
      procedure Evict(const Key: String); overload;
      procedure Put<V>(const Key: String; const Value: V); overload;
      procedure Put<V>(const Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      function GetOrMiss<V>(const Key: String; out Value: V): Boolean; overload;
      procedure Invalidate(); overload;
    public // cache per section
      procedure Evict(const Section, Key: String); overload;
      procedure Put<V>(const Section, Key: String; const Value: V); overload;
      procedure Put<V>(const Section, Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      function GetOrMiss<V>(const Section, Key: String; out Value: V): Boolean; overload;
      procedure Invalidate(const Section: String); overload;
    public
      constructor Create(const OwnsValues: Boolean;
                         const DefaultExpiresInMillis: Int64 = -1);
      destructor Destroy(); override;
    end;

  TCacheManager = class sealed
    strict private
      class var FGlobalCacheTable: TSectionCacheTable;
    public // general cache section
      class procedure Evict(const Key: String); overload;
      class procedure Put<V>(const Key: String; const Value: V); overload;
      class procedure Put<V>(const Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      class function GetOrMiss<V>(const Key: String; out Value: V): Boolean; overload;
      class procedure Invalidate(); overload;
    public // cache per section
      class procedure Evict(const Section, Key: String); overload;
      class procedure Put<V>(const Section, Key: String; const Value: V); overload;
      class procedure Put<V>(const Section, Key: String; const ExpiresInMillis: Int64; const Value: V); overload;
      class function GetOrMiss<V>(const Section, Key: String; out Value: V): Boolean; overload;
      class procedure Invalidate(const Section: String); overload;
    public
      class constructor Initialize();
      class destructor Unitialize();
    end;

implementation

{ TCacheTable }

constructor TCacheTable.Create(
  const OwnsValues: Boolean;
  const DefaultExpiresInMillis: Int64 = -1);
begin
  FOwnsValues := OwnsValues;
  FDefaultExpiresInMillis := DefaultExpiresInMillis;
  FRWSync := TMultiReadExclusiveWriteSynchronizer.Create();
  FCacheDictionary := TObjectDictionary<String, TCacheValue>.Create([doOwnsValues]);
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
  lCacheValue: TCacheValue;
  lExpiresInMillis: Integer;
begin
  lExpiresInMillis := FDefaultExpiresInMillis;
  FRWSync.BeginWrite();
  try
    if ExpiresInMillis <> -1 then
      lExpiresInMillis := ExpiresInMillis;

    lCacheValue := TCacheValue.Create(
        TValue.From<V>(Value),
        lExpiresInMillis,
        FOwnsValues);

    FCacheDictionary.AddOrSetValue(Key, lCacheValue);
  finally
    FRWSync.EndWrite();
  end;
end;

function TCacheTable.GetOrMiss<V>(
  const Key: String;
  out Value: V): Boolean;
var
  lCacheValue: TCacheValue;
begin
  Result := False;
  FRWSync.BeginRead();
  try
    if not FCacheDictionary.TryGetValue(Key, lCacheValue) then
    begin
      Value := Default(V);
      Result := False;
      Exit;
    end;

    if lCacheValue.ElapsedMillis < lCacheValue.ExpiresInMillis then
    begin
      Value := lCacheValue.ResolveValue<V>();
      Result := True;
      Exit;
    end;
  finally
    FRWSync.EndRead();
  end;

  FRWSync.BeginWrite();
  try
    if FCacheDictionary.TryGetValue(Key, lCacheValue) then
    begin
      FCacheDictionary.Remove(Key);
      Result := False;
      Exit;
    end;
  finally
    FRWSync.EndWrite();
  end;
end;

procedure TCacheTable.Evict(const Key: String);
begin
  FRWSync.BeginWrite();
  try
    FCacheDictionary.Remove(Key);
  finally
    FRWSync.EndWrite();
  end;
end;

procedure TCacheTable.Invalidate();
begin
  FRWSync.BeginWrite();
  try
    FCacheDictionary.Clear();
  finally
    FRWSync.EndWrite();
  end;
end;

destructor TCacheTable.Destroy();
begin
  Invalidate();
  FRWSync := nil;
  FCacheDictionary.Free();
  inherited;
end;

{ TCacheTable.TCacheValue }

constructor TCacheTable.TCacheValue.Create(
  const Value: TValue;
  const ExpiresInMillis: Int64;
  const OwnsValues: Boolean);
begin
  FValue := Value;
  FOwnsValues := OwnsValues;

  if FExpiresInMillis <> -1 then
    FStopwatch := TStopwatch.StartNew();

  FExpiresInMillis := ExpiresInMillis;
end;

function TCacheTable.TCacheValue.GetElapsedMillis(): Int64;
begin
  Result := FStopwatch.ElapsedMilliseconds;
end;

function TCacheTable.TCacheValue.ResolveValue<V>(): V;
var
  lValue: TValue;
  lVTypeInfo: PTypeInfo;
begin
  lValue := FValue;
  lVTypeInfo := TypeInfo(V);

  if (FValue.IsEmpty) or (lVTypeInfo = nil) then
  begin
    Result := Default(V);
    Exit;
  end;

  if lVTypeInfo <> FValue.TypeInfo then
    lValue := FValue.Cast<V>(True);

  Result := lValue.AsType<V>();
end;

destructor TCacheTable.TCacheValue.Destroy();
var
  lObject: TObject;
begin
  FStopwatch.Stop();

  if (not FOwnsValues) or (FValue.IsEmpty) then
    Exit;

  if FValue.Kind = tkClass then
  begin
    lObject := FValue.AsObject;
    if Assigned(lObject) then
      lObject.Free();
  end;

  inherited;
end;

{ TSectionCacheTable }

constructor TSectionCacheTable.Create(
  const OwnsValues: Boolean;
  const DefaultExpiresInMillis: Int64 = -1);
begin
  FSectionsCount := AVAILABLE_SECTIONS;

  SetLength(FSections, FSectionsCount);

  for var I := 0 to FSectionsCount - 1 do
  begin
    FSections[I] := TCacheTable.Create(
        OwnsValues,
        DefaultExpiresInMillis);
  end;
end;

procedure TSectionCacheTable.Evict(
  const Key: String);
begin
  FSections[0].Evict(Key);
end;

function TSectionCacheTable.GetOrMiss<V>(
  const Key: String;
  out Value: V): Boolean;
begin
  Result := FSections[0].GetOrMiss<V>(Key, Value);
end;

function TSectionCacheTable.GetOrMiss<V>(
  const Section, Key: String;
  out Value: V): Boolean;
var
  lSectionIndex: Integer;
begin
  lSectionIndex := GetSectionIndex(Section);
  Result := FSections[lSectionIndex].GetOrMiss<V>(Key, Value);
end;

procedure TSectionCacheTable.Invalidate(
  const Section: String);
var
  lSectionIndex: Integer;
begin
  lSectionIndex := GetSectionIndex(Section);
  FSections[lSectionIndex].Invalidate();
end;

procedure TSectionCacheTable.Invalidate();
begin
  FSections[0].Invalidate();
end;

procedure TSectionCacheTable.Put<V>(
  const Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
begin
  FSections[0].Put<V>(Key, ExpiresInMillis, Value);
end;

procedure TSectionCacheTable.Put<V>(
  const Key: String;
  const Value: V);
begin
  FSections[0].Put<V>(Key, Value);
end;

procedure TSectionCacheTable.Evict(
  const Section, Key: String);
var
  lSectionIndex: Integer;
begin
  lSectionIndex := GetSectionIndex(Section);
  FSections[lSectionIndex].Evict(Key);
end;

procedure TSectionCacheTable.Put<V>(
  const Section, Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
var
  lSectionIndex: Integer;
begin
  lSectionIndex := GetSectionIndex(Section);
  FSections[lSectionIndex].Put<V>(Key, ExpiresInMillis, Value);
end;

procedure TSectionCacheTable.Put<V>(
  const Section, Key: String;
  const Value: V);
var
  lSectionIndex: Integer;
begin
  lSectionIndex := GetSectionIndex(Section);
  FSections[lSectionIndex].Put<V>(Key, Value);
end;

function TSectionCacheTable.GetSectionIndex(
  const Section: String): Integer;
begin
  Result := 1 + (Abs(Section.GetHashCode()) mod (FSectionsCount - 1));
end;

destructor TSectionCacheTable.Destroy();
begin
  for var I := 0 to FSectionsCount - 1 do
    FreeAndNil(FSections[I]);
  inherited;
end;

{ TCacheManager }

class constructor TCacheManager.Initialize();
begin
  FGlobalCacheTable := TSectionCacheTable.Create(
      True,
      Round(TTimeSpan.FromMinutes(2).TotalMilliseconds));
end;

class procedure TCacheManager.Evict(
  const Key: String);
begin
  FGlobalCacheTable.Evict(Key);
end;

class procedure TCacheManager.Evict(
  const Section, Key: String);
begin
  FGlobalCacheTable.Evict(Section, Key);
end;

class function TCacheManager.GetOrMiss<V>(
  const Section, Key: String;
  out Value: V): Boolean;
begin
  Result := FGlobalCacheTable.GetOrMiss<V>(Section, Key, Value);
end;

class function TCacheManager.GetOrMiss<V>(
  const Key: String;
  out Value: V): Boolean;
begin
  Result := FGlobalCacheTable.GetOrMiss<V>(Key, Value);
end;

class procedure TCacheManager.Invalidate();
begin
  FGlobalCacheTable.Invalidate();
end;

class procedure TCacheManager.Invalidate(
  const Section: String);
begin
  FGlobalCacheTable.Invalidate(Section);
end;

class procedure TCacheManager.Put<V>(
  const Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
begin
  FGlobalCacheTable.Put<V>(Key, ExpiresInMillis, Value);
end;

class procedure TCacheManager.Put<V>(
  const Key: String;
  const Value: V);
begin
  FGlobalCacheTable.Put<V>(Key, Value);
end;

class procedure TCacheManager.Put<V>(
  const Section, Key: String;
  const Value: V);
begin
  FGlobalCacheTable.Put<V>(Section, Key, Value);
end;

class procedure TCacheManager.Put<V>(
  const Section, Key: String;
  const ExpiresInMillis: Int64;
  const Value: V);
begin
  FGlobalCacheTable.Put<V>(Section, Key, ExpiresInMillis, Value);
end;

class destructor TCacheManager.Unitialize();
begin
  FreeAndNil(FGlobalCacheTable);
end;

end.
