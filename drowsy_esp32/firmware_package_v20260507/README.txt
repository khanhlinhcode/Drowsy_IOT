═══════════════════════════════════════════════════
  DROWSY MONITOR — ESP32 FIRMWARE PACKAGE
═══════════════════════════════════════════════════

Gồm có:
  - firmware.bin     : Chương trình chính ESP32
  - bootloader.bin   : Bootloader
  - partitions.bin   : Bảng phân vùng
  - flash_drowsy.sh  : Script flash tự động

CÁCH FLASH:
  1. Cài Python3 (nếu chưa có)
  2. Cắm ESP32 vào USB
  3. Mở Terminal, chạy:

     bash flash_drowsy.sh

  Script sẽ tự cài esptool, tìm ESP32, và flash.

SAU KHI FLASH:
  1. ESP32 tạo WiFi hotspot "DROWSY-SETUP-xxxx"
  2. Kết nối điện thoại vào hotspot đó
  3. Mở trình duyệt → nhập WiFi SSID + Password
  4. ESP32 sẽ kết nối WiFi và sẵn sàng hoạt động

RESET WIFI:
  Nhấn giữ nút BOOT trên ESP32 trong 5 giây

═══════════════════════════════════════════════════
