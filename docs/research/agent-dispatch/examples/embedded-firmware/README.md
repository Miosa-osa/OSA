# Example: Embedded Firmware — Memory Safety + OTA Update Fix Sprint

> Fictional IoT sensor node firmware. C17 + C++20 (partial) + FreeRTOS + STM32 HAL + MQTT + custom bootloader.

Demonstrates:

- **Execution traces** tracing bare-metal bugs from interrupt handler entry point down to register-level root cause (e.g., `OTA_IRQHandler` → `flash_write_page()` → DMA buffer alignment fault)
- **Chain execution** — complete the OTA flash corruption fix before starting heap fragmentation work, because a corrupted bootloader blocks all other testing
- **Execution pace** — DATA works extremely slowly and carefully through memory-mapped I/O and DMA register sequences; INFRA works fast on CMake, linker scripts, and CI pipeline configuration
- **Cross-layer tracing** from C++ application layer (`SensorManager::publish()`) down through the HAL (`HAL_FLASH_Program()`), into raw peripheral register writes (`FLASH->CR |= FLASH_CR_PG`), and finally to oscilloscope/logic analyzer confirmation
