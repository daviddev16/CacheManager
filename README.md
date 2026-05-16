# CacheManager

A simple, thread-safe, and generic in-memory caching library for Delphi. Features time-based expiration (TTL) and automatic memory management for cached objects.

## Quick Start

`TCacheManager` is a ready-to-use global singleton. It supports standard global caching or section-based caching to organize keys and improve multi-threading performance.

```pascal
uses
  CacheManager;

var
  CachedString: string;
begin
  // 1. Basic Put & Get (Defaults to 2-minute expiration)
  TCacheManager.Put<string>('MyKey', 'Hello World!');
  
  if TCacheManager.GetOrMiss<string>('MyKey', CachedString) then
    Writeln('Hit: ', CachedString)
  else
    Writeln('Miss or Expired!');

  // 2. Custom Expiration (e.g., 5 seconds = 5000ms)
  TCacheManager.Put<Integer>('TimeoutKey', 5000, 42);

  // 3. Object Caching (Cache takes ownership and frees objects on expiration)
  TCacheManager.Put<TStringList>('ListKey', TStringList.Create);

  // 4. Section-based Caching (Prevents key collisions and boosts concurrency)
  TCacheManager.Put<string>('Customers', 'Cust_123', 'John Doe');
  TCacheManager.GetOrMiss<string>('Customers', 'Cust_123', CachedString);

  // 5. Invalidation
  TCacheManager.Invalidate('Customers'); // Clears only the 'Customers' section
  TCacheManager.Invalidate();            // Clears only the general cache
end;
```

## Features at a Glance
- **Thread-Safe:** Uses `IReadWriteSync` for high concurrency.
- **Generics:** Store any primitive or object (`TValue` powered).
- **Auto Memory Management:** Automatically frees owned objects upon expiration/eviction.
- **Section Partitioning:** Distributes locks across up to 32 slots.
