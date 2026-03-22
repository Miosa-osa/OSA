# Sprint 04 Dispatch — Memory Safety + OTA Update Fix

> Fix OTA firmware corruption, heap exhaustion watchdog resets, and MQTT data loss. Harden memory safety across DMA, stack, and MPU.
> Stack: C17 + C++20 (partial) + FreeRTOS heap_4 + STM32H7 HAL + MQTT + custom bootloader (512KB flash)

## Sprint Goals

1. Fix OTA firmware update corruption (CRC check passes but flashed image is corrupted — write buffer overflow in flash driver)
2. Fix heap fragmentation causing watchdog resets after ~72 hours of continuous operation (FreeRTOS heap_4 exhaustion)
3. Fix MQTT reconnection dropping sensor data (ring buffer overwrite during reconnect — ISR vs. task race condition)
4. Harden memory safety: stack canaries, MPU region configuration, bounds checking on all DMA buffers

## Execution Traces

### Chain 1: OTA Firmware Corruption (P0 — Device Bricked)
```
NVIC → OTA_IRQHandler()  [src/ota/ota_handler.c]
→ ota_process_chunk()    [src/ota/ota_handler.c:214]
→ flash_write_page()     [src/drivers/flash_driver.c:88]
→ HAL_FLASH_Program()    [STM32H7 HAL — stm32h7xx_hal_flash.c]
→ DMA2_Stream0 transfer  [FLASH->CR, DMA2->LISR]

Signal: 32-byte write buffer in flash_write_page() is not aligned to STM32H7
flash word size (256 bits = 32 bytes). When ota_process_chunk() feeds a
128-byte chunk, the final partial write overruns the stack-allocated
write_buf[32] by 0–31 bytes depending on chunk remainder. CRC is computed
over the pre-DMA buffer (correct data), not the post-write readback (corrupted).
Device accepts update, reboots into corrupted image, enters HardFault loop.

Debug approach:
  1. JTAG live watch on write_buf address during OTA transfer
  2. Logic analyzer on SWD bus — capture FLASH->SR error flags
  3. Readback flash page immediately after write, diff against source buffer
  4. Add __attribute__((aligned(32))) to write_buf; add post-write verify step
```

### Chain 2: Heap Fragmentation / Watchdog Reset (P1)
```
SensorTask  [src/tasks/sensor_task.cpp:67]
→ SensorManager::read_all()      [src/app/sensor_manager.cpp:130]
→ SensorReading* r = new SensorReading()   [C++ heap via pvPortMalloc]
→ publish_queue_push(r)          [src/app/publish_queue.cpp:44]
→ ... (reading consumed by MQTTTask)
→ delete r                       [pvPortFree — back to heap_4]

Signal: SensorTask allocates/frees a SensorReading struct (48 bytes) at 10 Hz.
MQTTTask frees at variable rate (network-dependent). After ~72 hours,
heap_4 free list is fragmented into ~80 blocks of 40–56 bytes.
A 512-byte MQTT payload allocation in mqtt_build_payload() fails (NULL return).
pvPortMalloc failure is not checked — NULL pointer dereference triggers HardFault.
IWDG watchdog fires 2 seconds later. Reboot loop begins.

Debug approach:
  1. Call xPortGetFreeHeapSize() and xPortGetMinimumEverFreeHeapSize() from
     a debug task every 60s; log over UART
  2. Enable configUSE_MALLOC_FAILED_HOOK and configCHECK_FOR_STACK_OVERFLOW
     in FreeRTOSConfig.h
  3. Use heap_4 walk: iterate heap_4's free list manually in GDB to count
     fragmentation (print xStart.pxNextFreeBlock chain)
  4. Fix: switch SensorReading to a statically allocated FreeRTOS
     message buffer (xMessageBufferCreate) or a fixed-size pool allocator
     (pvPortMalloc once at init, ring through pre-allocated array)
```

### Chain 3: MQTT Reconnect Drops Sensor Data (P1)
```
MQTT keepalive timeout → mqtt_reconnect_cb()  [src/net/mqtt_client.c:301]
→ ring_buffer_reset(&sensor_rb)               [src/util/ring_buffer.c:55]
→ ... concurrently ...
SensorISR (TIM6 IRQ, 100 Hz) → ring_buffer_push(&sensor_rb, &sample)
                                               [src/util/ring_buffer.c:29]

Signal: mqtt_reconnect_cb() calls ring_buffer_reset() from MQTT task context
to flush stale data before reconnect. ring_buffer_reset() writes rb->head = 0
and rb->tail = 0. Concurrently, TIM6_DAC_IRQHandler fires at 100 Hz and calls
ring_buffer_push(), which reads the non-atomic head/tail pair mid-reset.
Race produces head > capacity or tail wrapping past head, corrupting the
ring buffer index state. Subsequent push/pop operations silently overwrite
valid samples or return garbage. Data loss is silent — no assertion fires.

Debug approach:
  1. Logic analyzer on TIM6 interrupt line + UART TX (MQTT reconnect log)
     to confirm interleaving
  2. Add __DSB() / __ISB() memory barriers around head/tail writes in
     ring_buffer_reset() and ring_buffer_push()
  3. Fix: taskENTER_CRITICAL() / taskEXIT_CRITICAL() around ring_buffer_reset()
     in MQTT task context; make ring_buffer_push() ISR-safe with
     UBaseType_t uxSavedInterruptStatus = taskENTER_CRITICAL_FROM_ISR()
  4. Add ring buffer integrity assertion: assert(rb->head < rb->capacity &&
     rb->tail < rb->capacity) at push/pop entry
```

### Chain 4: Memory Safety Hardening (P2)
```
Targets:
  - Stack canaries:  all FreeRTOS tasks (configCHECK_FOR_STACK_OVERFLOW = 2)
  - MPU regions:     lock .rodata as read-only, guard DMA source/dest buffers
  - DMA bounds:      verify HAL_DMA_Start_IT() length param against buffer size
  - Null checks:     all pvPortMalloc / new return values

Signal: No active canaries or MPU configuration in current build.
Buffer overflow in Chain 1 and heap corruption in Chain 2 are detectable only
after HardFault. MPU can catch them at the boundary crossing.

DMA audit targets:
  - DMA2_Stream0: flash write DMA — no length guard (Chain 1 root)
  - DMA1_Stream1: ADC sample DMA — adc_dma_buf[64] passed as length 128 in
    HAL_ADC_Start_DMA() call at src/drivers/adc_driver.c:47 (off-by-one)
  - USART3 TX DMA — length derived from strlen() on non-null-terminated
    scratch buffer at src/net/uart_transport.c:89

Hardening approach:
  1. Add vApplicationStackOverflowHook() with UART fault dump + NVIC_SystemReset()
  2. Configure MPU with ARM_MPU_SetRegion() for:
       Region 0: Flash (RO, privileged+unprivileged)
       Region 1: SRAM (RW, privileged only for DMA descriptors)
       Region 2: Peripheral space (Device memory, XN)
  3. Macro: DMA_SAFE_START(stream, src, dst, len, buf_size) — static_assert +
     runtime assert before every HAL_DMA_Start_IT()
  4. Run host-side unit tests under Valgrind (mocked HAL stubs) to catch
     buffer overruns before flashing hardware
```

## Wave Assignments

### Wave 1 — Foundation (unblock hardware testing)

| Agent | Focus | Chains |
|-------|-------|--------|
| DATA | Fix `flash_write_page()` alignment bug; add post-write readback verify; fix DMA2_Stream0 length guard | Chain 1 (flash driver — must land first, blocks all OTA testing) |
| INFRA | Update CMakeLists.txt: enable `-fstack-protector-strong`, `-Wstack-usage=512`, AddressSanitizer for host build; add `make test-host` target | Chain 4 (build system — fast work, unblocks QA) |

### Wave 2 — Core Bug Fixes

| Agent | Focus | Chains |
|-------|-------|--------|
| BACKEND | Fix `ring_buffer_reset()` / `ring_buffer_push()` race: add `taskENTER_CRITICAL_FROM_ISR()`, `__DSB()` barriers, integrity assertions | Chain 3 |
| SERVICES | Replace `new SensorReading` hot path with fixed-size pool allocator (`sensor_pool_alloc()` / `sensor_pool_free()`); add heap watermark logging task | Chain 2 |
| BACKEND | Add `vApplicationStackOverflowHook()` UART fault dump; configure MPU regions for flash + SRAM + peripheral space; add `DMA_SAFE_START` macro to all three DMA call sites | Chain 4 |

### Wave 3 — Validation + Hardening Verification

| Agent | Focus | Chains |
|-------|-------|--------|
| QA | Write host-side unit tests (mocked HAL stubs) under Valgrind: OTA chunk boundary cases, ring buffer ISR/task interleave simulation, pool allocator exhaustion path | All chains |
| FRONTEND | Update OTA progress UI on companion app: show per-chunk verify status, surface `FLASH_SR` error codes as human-readable strings over MQTT `ota/status` topic | Chain 1 (user-visible confirmation) |

## Merge Order

```
1. INFRA  → main  (build system: ASan host target, stack warnings — unblocks QA)
2. DATA  → main  (flash driver fix — P0, unblocks all OTA hardware testing)
3. BACKEND    → main  (ring buffer race fix)
4. SERVICES    → main  (pool allocator — resolves heap fragmentation)
5. BACKEND    → main  (MPU + canaries + DMA bounds — hardening layer over all fixes)
6. FRONTEND    → main  (OTA status UI)
7. QA     → main  (host tests + Valgrind clean run validates everything)
```

Note: DATA must not be merged until logic analyzer confirms post-write readback
passes for all chunk-size boundary cases (1 byte, 31 bytes, 32 bytes, 33 bytes, 128 bytes).

## Success Criteria

- [ ] OTA update succeeds for 20 consecutive transfers at all chunk sizes (32, 64, 128, 256 bytes); post-write readback matches source buffer byte-for-byte
- [ ] CRC verification uses readback data, not pre-DMA buffer
- [ ] Heap watermark log shows stable free heap over 96-hour soak test (no downward trend)
- [ ] Zero watchdog resets in 96-hour soak test (was: reset at ~72 hours)
- [ ] Ring buffer integrity assertion never fires during MQTT reconnect stress test (100 reconnects, sensor ISR running at 100 Hz)
- [ ] Zero sensor samples dropped during MQTT reconnection (verified by sequence number check on broker side)
- [ ] MPU HardFault fires correctly when test harness deliberately writes to read-only flash region
- [ ] `vApplicationStackOverflowHook()` triggers and dumps fault info over UART when stack overflow is injected in test task
- [ ] All DMA call sites pass `DMA_SAFE_START` bounds check (static_assert clean at compile time)
- [ ] Valgrind reports zero errors on host-side test suite (`make test-host` clean)
- [ ] `addrsan` (ASan) host build clean on all four chain test cases
