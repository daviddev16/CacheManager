# CacheManager

A simple, thread-safe, and generic in-memory caching library for Delphi. Features time-based expiration (TTL), strict capacity limits, and an efficient O(1) Least Recently Used (LRU) eviction policy.

## Quick Start

`TCacheManager` is a ready-to-use global singleton. It supports standard global caching with time-based expiration and capacity limits.

```pascal
uses
  CacheManager;

var
  CachedString: string;
begin
  // 1. Basic Put & Get (Defaults to 5-minute expiration, 128 capacity)
  TCacheManager.Put<string>('MyKey', 'Hello World!');
  
  if TCacheManager.GetOrMiss<string>('MyKey', CachedString) then
    Writeln('Hit: ', CachedString)
  else
    Writeln('Miss or Expired!');

  // 2. Custom Expiration (e.g., 5 seconds = 5000ms)
  TCacheManager.Put<Integer>('TimeoutKey', 5000, 42);

  // 3. Evict specific key
  TCacheManager.Evict('MyKey');

  // 4. Invalidation
  TCacheManager.EvictAll(); // Clears all cached items
end;
```

### Standalone Cache Instances (Thread-Safe)

If you need localized caches or multiple partitions (e.g., to replace section-based caches), you can directly instantiate `TCacheTable` since it is fully thread-safe:

```pascal
var
  UserCache: TCacheTable;
begin
  // Capacity: 100 items, Default TTL: 1 minute (60000ms)
  UserCache := TCacheTable.Create(100, 60000);
  try
    UserCache.Put<string>('User_1', 'Alice');
  finally
    UserCache.Free();
  end;
end;
```

### Iterating the Cache Table

Since `TCacheTable` inherits from `TEnumerable<TCachePair>`, you can iterate over all cached items using a standard `for..in` loop. Each item retrieved is a `TCachePair` record containing the `Key` and the `Value` (as a `TCacheValue` wrapper):

```pascal
var
  Pair: TCachePair;
  UserCache: TCacheTable;
begin
  UserCache := TCacheTable.Create(100, 60000);
  try
    UserCache.Put<string>('User_1', 'Alice');
    UserCache.Put<string>('User_2', 'Bob');

    // Iterating the cache
    for Pair in UserCache do
    begin
      Writeln('Key: ', Pair.Key);
      Writeln('Value: ', Pair.Value.AsValue<string>());
    end;
  finally
    UserCache.Free();
  end;
end;
```

## Features at a Glance

- **Thread-Safe:** Uses `IReadWriteSync` (`TMultiReadExclusiveWriteSynchronizer`) for high concurrency.
- **O(1) LRU Eviction:** Employs a Doubly Linked List alongside a Dictionary to manage cache capacity efficiently.
- **Generics:** Store primitive types, records, and unmanaged types.
- **Enumerable:** `TCacheTable` implements `TEnumerable<TCachePair>` for clean iteration.

## Change Log

### Inclusions

- **O(1) LRU Cache Eviction:** Added a doubly-linked list (`TDoublyLinkedList`) paired with `TDictionary` to support capacity limits with O(1) eviction of the eldest items.
- **Record Node Storage:** Swapped out heavy class-based wrapper allocations (`TCacheValue`) for lighter pointer-record nodes (`PValueNode` / `TValueNode`), reducing overhead and memory fragmentation.
- **`TEnumerable` Support:** `TCacheTable` now implements `TEnumerable<TCachePair>`, supporting custom enumeration (`TCachePairEnumerator`) and iteration over cached pairs.
- **Thread-Safe Standalone Instances:** Exposes the `TCacheTable` class directly, allowing users to create thread-safe local or singleton caches with custom capacities and default TTLs.

### Exclusions

- **Section-based Cache (`TSectionCacheTable`):** Completely removed. It could not handle section hash collisions and to not increase the overhead of doing another lookup on a `TDictionary` whereas the Section is the Key. It is a design choice.
  - *Alternative:* If section-based caching is needed, just create a Singleton/standalone instance of `TCacheTable` (which is thread-safe).
- **Managed Objects Ownership / Auto-freeing (`FOwnsValues`):** Removed `TObjectDictionary` and class ownership mechanisms. Values must be unmanaged/primitive types or records. Classes, interfaces, class references, and managed records are not supported and will raise an `ECacheException` to prevent memory leaks and undefined behavior.
