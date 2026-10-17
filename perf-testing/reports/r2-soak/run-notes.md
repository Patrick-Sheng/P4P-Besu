
## smoke - started 2026-10-15 06:53:30 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 159 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## seed - started 2026-10-15 07:02:22 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 159 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## seed - started 2026-10-15 11:33:04 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 158 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## seed - started 2026-10-15 11:37:13 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 158 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## seed - started 2026-10-15 12:41:59 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 157 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## calibrate - started 2026-10-15 17:24:18 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 141 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx2048m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## calibrate - started 2026-10-15 21:39:20 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 141 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## soak - started 2026-10-15 23:55:16 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 142 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 150 votes/s from round 1
- Round 1: start 2026-10-15 23:55:19
- Round 1: end 2026-10-16 00:18:22 (200000 ok, p95 37005 ms)
- Round 2: start 2026-10-16 00:18:22

## soak - started 2026-10-16 00:53:49 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 142 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 120 votes/s from round 1
- Round 1: start 2026-10-16 00:53:53

## soak - started 2026-10-16 02:01:37 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 142 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 120 votes/s from round 1
- Round 1: start 2026-10-16 02:01:40

## soak - started 2026-10-16 02:20:12 UTC

- Git commit: cc2d99c (20 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 142 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 120 votes/s from round 1
- Round 1: start 2026-10-16 02:29:22
- Round 1: end 2026-10-16 02:58:29 (200000 ok, p95 35026 ms)
- Round 2: start 2026-10-16 02:58:29

## soak - started 2026-10-16 03:11:26 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 139 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 120 votes/s from round 2
- Round 2: start 2026-10-16 03:24:10
- Round 2: end 2026-10-16 03:49:21 (174480 ok, p95 11652 ms)
- Round 3: start 2026-10-16 03:49:21

## soak - started 2026-10-16 04:05:57 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 139 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 120 votes/s from round 3
- Round 3: start 2026-10-16 04:18:24

## soak - started 2026-10-16 04:34:02 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 138 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 14 rounds x 200000 votes at 90 votes/s from round 3
- Round 3: start 2026-10-16 04:43:03
- Round 3: end 2026-10-16 04:54:05 (58253 ok, p95 3577 ms)
- Round 4: start 2026-10-16 04:54:05

## soak - started 2026-10-16 05:34:45 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 138 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
- Soak: 5 rounds x 200000 votes at 90 votes/s from round 4
- Round 4: start 2026-10-16 05:45:06
- Round 4: end 2026-10-16 05:51:09 (28623 ok, p95 6787 ms)
- Round 5: start 2026-10-16 05:51:09
- Area 3 checkpoint 1M: attacks start 2026-10-16 06:13:16
- Round 5: end 2026-10-16 06:29:24 (200000 ok, p95 9282 ms)

## soak-attacks - started 2026-10-16 06:30:52 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 133 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## soak-attacks - started 2026-10-16 06:46:50 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 137 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```

## area2 - started 2026-10-16 06:55:11 UTC

- Git commit: cc2d99c (21 uncommitted changes)
- Besu: besu/v24.12.0/linux-x86_64/openjdk-java-21
- VM: 6 vCPU (Intel(R) Core(TM) Ultra 5 125H), MemTotal 15988 MiB, swap 0 MiB, disk free 137 GB
- Genesis: chainId 1337, ibft2 {"blockperiodseconds":2,"epochlength":30000,"requesttimeoutseconds":4}, gasLimit 0x1fffffffffffff
- Contract: 0x58D7831eAcC6F61d92E5Fd951D4B11cF8DfDE5a8
- Validator launch (validator1):
  ```
  env: "JAVA_OPTS=-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=128m -XX:+ExitOnOutOfMemoryError -Xlog:gc:file=/home/patrick/P4P/P4P-Besu/perf-testing/network/generated/n4/validator1-gc.log:uptime,time:filecount=2,filesize=20m" MALLOC_ARENA_MAX=2 
  /opt/besu/bin/besu --data-path=generated/n4/data-native/validator1 --genesis-file=generated/n4/config/genesis.json --node-private-key-file=generated/n4/config/keys/0x52914145d3337c85e3e5da19693635886ab598b2/key --data-storage-format=BONSAI --rpc-http-enabled --rpc-http-api=ETH,NET,IBFT,ADMIN,DEBUG,TXPOOL --rpc-http-host=127.0.0.1 --rpc-http-port=20400 --rpc-http-cors-origins=* --host-allowlist=* --p2p-host=127.0.0.1 --p2p-port=30400 --tx-pool-max-size=65536 --metrics-enabled --metrics-host=127.0.0.1 --metrics-port=9400 --profile=ENTERPRISE --Xplugin-rocksdb-cache-capacity=33554432 --Xplugin-rocksdb-background-thread-count=1 --logging=INFO 
  ```
