#ifndef OLED_STATUS_H
#define OLED_STATUS_H

#include <Arduino.h>

#ifndef OLED_ENABLED
#define OLED_ENABLED 1
#endif

#define OLED_DRIVER_SSD1306 1
#define OLED_DRIVER_SH1106 2

#ifndef OLED_DRIVER
#define OLED_DRIVER OLED_DRIVER_SSD1306
#endif

#ifndef OLED_SDA
#define OLED_SDA 26
#endif

#ifndef OLED_SCL
#define OLED_SCL 27
#endif

#ifndef OLED_ADDR
#define OLED_ADDR 0x3C
#endif

#ifndef OLED_ADDR_FALLBACK
#define OLED_ADDR_FALLBACK 0x3D
#endif

#ifndef OLED_REFRESH_MS
#define OLED_REFRESH_MS 120
#endif

#ifndef OLED_BOOT_SPLASH_MS
#define OLED_BOOT_SPLASH_MS 2000
#endif

#ifndef OLED_ROBOT_MODE_AFTER_MS
#define OLED_ROBOT_MODE_AFTER_MS 12000
#endif

#ifndef OLED_ROBOT_SWAP_MS
#define OLED_ROBOT_SWAP_MS 2000
#endif

struct OledStatusSnapshot {
  bool wifiConnected = false;
  bool mqttReady = false;
  bool piLinkReady = false;
  bool espIpKnown = false;
  bool piIpKnown = false;
  bool faceLocked = false;
  bool armed = false;
  bool drowsyAlert = false;
  bool restWarning = false;
  bool progressFromPi = false;
  uint8_t progressPct = 0;
  char espIp[16] = {0};
  char piIp[16] = {0};
};

class OledStatusDisplay {
 public:
  OledStatusDisplay();

  void begin(uint32_t nowMs = 0);
  void update(uint32_t nowMs, const OledStatusSnapshot& snapshot);
  bool available() const;

 private:
  bool _available = false;
  bool _initialized = false;
  uint8_t _addr = 0;
  uint32_t _bootMs = 0;
  uint32_t _lastDrawMs = 0;
  uint32_t _connectingSinceMs = 0;

  bool initDisplay();
  void drawFrame(uint32_t nowMs, const OledStatusSnapshot& snapshot);

  // Premium UI drawing helpers
  void drawBootSplash(uint32_t nowMs);
  void drawConnecting(uint32_t nowMs, const OledStatusSnapshot& snapshot,
                      bool espReady, bool piReady);
  void drawCalibration(uint32_t nowMs, const OledStatusSnapshot& snapshot,
                       uint8_t pct);
  void drawActive(uint32_t nowMs, const OledStatusSnapshot& snapshot);
  void drawDrowsyAlert(uint32_t nowMs, const OledStatusSnapshot& snapshot);
  void drawRestWarning(uint32_t nowMs, const OledStatusSnapshot& snapshot);
  void drawProgressBar(int x, int y, int w, int h, uint8_t pct);
  void drawStatusIcon(int x, int y, uint8_t type);
  void drawHeaderLine(const char* title);
};

#endif  // OLED_STATUS_H
