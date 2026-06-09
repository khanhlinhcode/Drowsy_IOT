#include "oled_status.h"

#if OLED_ENABLED
#include <Adafruit_GFX.h>
#include <Wire.h>

#if OLED_DRIVER == OLED_DRIVER_SH1106
#include <Adafruit_SH110X.h>
#else
#include <Adafruit_SSD1306.h>
#endif
#endif

namespace {
constexpr uint8_t OLED_WIDTH = 128;
constexpr uint8_t OLED_HEIGHT = 64;
constexpr uint8_t OLED_TEXT_COLOR = 1;
constexpr uint8_t OLED_FONT_SCALE = 1;

// ─── Animated robot face for long waits ───
void drawRobotFace(Adafruit_GFX* display, bool altFrame) {
#if OLED_ENABLED
  if (display == nullptr) return;

  const int cx = 64;
  const int cy = 30;
  const int r = 18;
  display->drawCircle(cx, cy, r, OLED_TEXT_COLOR);
  display->drawCircle(cx, cy, r - 1, OLED_TEXT_COLOR);
  display->fillCircle(cx - r - 3, cy - 3, 2, OLED_TEXT_COLOR);
  display->fillCircle(cx + r + 3, cy - 3, 2, OLED_TEXT_COLOR);

  if (!altFrame) {
    display->fillCircle(cx - 7, cy - 4, 3, OLED_TEXT_COLOR);
    display->fillCircle(cx + 7, cy - 4, 3, OLED_TEXT_COLOR);
    display->drawRoundRect(cx - 10, cy + 6, 20, 6, 2, OLED_TEXT_COLOR);
  } else {
    display->drawLine(cx - 10, cy - 4, cx - 4, cy - 4, OLED_TEXT_COLOR);
    display->drawLine(cx + 4, cy - 4, cx + 10, cy - 4, OLED_TEXT_COLOR);
    display->drawRoundRect(cx - 10, cy + 6, 20, 6, 2, OLED_TEXT_COLOR);
    display->drawLine(cx - 8, cy + 9, cx + 8, cy + 9, OLED_TEXT_COLOR);
  }
#else
  (void)display;
  (void)altFrame;
#endif
}

// ─── WiFi icon (small 8x6 at position) ───
void drawWifiIcon(Adafruit_GFX* display, int x, int y, bool connected) {
#if OLED_ENABLED
  if (display == nullptr) return;
  if (connected) {
    // Three arcs for wifi signal
    display->drawPixel(x + 3, y + 5, OLED_TEXT_COLOR);  // dot
    display->drawLine(x + 2, y + 3, x + 4, y + 3, OLED_TEXT_COLOR);
    display->drawLine(x + 1, y + 1, x + 5, y + 1, OLED_TEXT_COLOR);
    display->drawLine(x + 0, y + 0, x + 6, y + 0, OLED_TEXT_COLOR);
  } else {
    // X mark for disconnected
    display->drawLine(x, y, x + 5, y + 5, OLED_TEXT_COLOR);
    display->drawLine(x + 5, y, x, y + 5, OLED_TEXT_COLOR);
  }
#else
  (void)display;
  (void)x;
  (void)y;
  (void)connected;
#endif
}

// ─── Checkmark icon ───
void drawCheck(Adafruit_GFX* display, int x, int y) {
#if OLED_ENABLED
  if (display == nullptr) return;
  display->drawLine(x, y + 3, x + 2, y + 5, OLED_TEXT_COLOR);
  display->drawLine(x + 2, y + 5, x + 5, y, OLED_TEXT_COLOR);
#else
  (void)display;
  (void)x;
  (void)y;
#endif
}

// ─── Eye icon (for calibration) ───
void drawEyeIcon(Adafruit_GFX* display, int cx, int cy, bool open) {
#if OLED_ENABLED
  if (display == nullptr) return;
  // Outer eye shape
  display->drawCircle(cx, cy, 6, OLED_TEXT_COLOR);
  if (open) {
    // Pupil
    display->fillCircle(cx, cy, 2, OLED_TEXT_COLOR);
  } else {
    // Closed eye — horizontal line
    display->drawLine(cx - 6, cy, cx + 6, cy, OLED_TEXT_COLOR);
  }
#else
  (void)display;
  (void)cx;
  (void)cy;
  (void)open;
#endif
}

// ─── Warning triangle icon ───
void drawWarningTriangle(Adafruit_GFX* display, int cx, int cy, int r) {
#if OLED_ENABLED
  if (display == nullptr) return;
  int x0 = cx;
  int y0 = cy - r;
  int x1 = cx - r;
  int y1 = cy + r;
  int x2 = cx + r;
  int y2 = cy + r;
  display->drawTriangle(x0, y0, x1, y1, x2, y2, OLED_TEXT_COLOR);
  display->drawTriangle(x0, y0 + 1, x1 + 1, y1, x2 - 1, y2, OLED_TEXT_COLOR);
  // Exclamation mark
  display->drawLine(cx, cy - r + 4, cx, cy + 1, OLED_TEXT_COLOR);
  display->drawPixel(cx, cy + 3, OLED_TEXT_COLOR);
#else
  (void)display;
  (void)cx;
  (void)cy;
  (void)r;
#endif
}

}  // namespace

#if OLED_ENABLED
static TwoWire gOledWire(1);

#if OLED_DRIVER == OLED_DRIVER_SH1106
static Adafruit_SH1106G* gOled = nullptr;
#else
static Adafruit_SSD1306* gOled = nullptr;
#endif
#endif

OledStatusDisplay::OledStatusDisplay() {}

bool OledStatusDisplay::available() const { return _available; }

void OledStatusDisplay::begin(uint32_t nowMs) {
#if !OLED_ENABLED
  (void)nowMs;
  _available = false;
  _initialized = true;
  return;
#else
  if (_initialized) return;
  _bootMs = (nowMs == 0) ? millis() : nowMs;
  _lastDrawMs = 0;
  gOledWire.begin(OLED_SDA, OLED_SCL, 400000U);
  _available = initDisplay();
  _initialized = true;
  if (_available) {
    OledStatusSnapshot bootSnapshot;
    drawFrame(_bootMs, bootSnapshot);
  }
#endif
}

void OledStatusDisplay::update(uint32_t nowMs, const OledStatusSnapshot& snapshot) {
#if !OLED_ENABLED
  (void)nowMs;
  (void)snapshot;
  return;
#else
  if (!_initialized) begin(nowMs);
  if (!_available) return;

  if (_lastDrawMs != 0 && (nowMs - _lastDrawMs) < OLED_REFRESH_MS) {
    return;
  }
  _lastDrawMs = nowMs;
  drawFrame(nowMs, snapshot);
#endif
}

bool OledStatusDisplay::initDisplay() {
#if !OLED_ENABLED
  return false;
#else
#if OLED_DRIVER == OLED_DRIVER_SH1106
  if (gOled == nullptr) {
    gOled = new Adafruit_SH1106G(OLED_WIDTH, OLED_HEIGHT, &gOledWire, -1);
  }
  if (gOled == nullptr) return false;

  if (gOled->begin(OLED_ADDR, true)) {
    _addr = OLED_ADDR;
  } else if (gOled->begin(OLED_ADDR_FALLBACK, true)) {
    _addr = OLED_ADDR_FALLBACK;
  } else {
    return false;
  }
#else
  if (gOled == nullptr) {
    gOled = new Adafruit_SSD1306(OLED_WIDTH, OLED_HEIGHT, &gOledWire, -1);
  }
  if (gOled == nullptr) return false;

  if (gOled->begin(SSD1306_SWITCHCAPVCC, OLED_ADDR, true, false)) {
    _addr = OLED_ADDR;
  } else if (gOled->begin(SSD1306_SWITCHCAPVCC, OLED_ADDR_FALLBACK, true, false)) {
    _addr = OLED_ADDR_FALLBACK;
  } else {
    return false;
  }
#endif
  return true;
#endif
}

// ═════════════════════════════════════════════════════════════
// Reusable UI components
// ═════════════════════════════════════════════════════════════

void OledStatusDisplay::drawHeaderLine(const char* title) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  gOled->setTextSize(1);
  gOled->setTextColor(OLED_TEXT_COLOR);
  gOled->setCursor(0, 0);
  gOled->print(title);
  // Separator line under header
  gOled->drawLine(0, 9, 127, 9, OLED_TEXT_COLOR);
#endif
}

void OledStatusDisplay::drawProgressBar(int x, int y, int w, int h, uint8_t pct) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  if (pct > 100) pct = 100;
  int fillW = (pct * (w - 2)) / 100;
  // Rounded border
  gOled->drawRoundRect(x, y, w, h, 2, OLED_TEXT_COLOR);
  if (fillW > 0) {
    gOled->fillRoundRect(x + 1, y + 1, fillW, h - 2, 1, OLED_TEXT_COLOR);
  }
#endif
}

void OledStatusDisplay::drawStatusIcon(int x, int y, uint8_t type) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  switch (type) {
    case 0:  // Safe — circle with check
      gOled->drawCircle(x + 4, y + 4, 4, OLED_TEXT_COLOR);
      drawCheck(gOled, x + 2, y + 2);
      break;
    case 1:  // Warning — triangle
      drawWarningTriangle(gOled, x + 4, y + 4, 4);
      break;
    case 2:  // Danger — filled circle with !
      gOled->fillCircle(x + 4, y + 4, 4, OLED_TEXT_COLOR);
      gOled->drawLine(x + 4, y + 1, x + 4, y + 5, 0);
      gOled->drawPixel(x + 4, y + 7, 0);
      break;
  }
#else
  (void)x;
  (void)y;
  (void)type;
#endif
}

// ═════════════════════════════════════════════════════════════
// Screen pages
// ═════════════════════════════════════════════════════════════

void OledStatusDisplay::drawBootSplash(uint32_t nowMs) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  (void)nowMs;

  // ─── Premium boot screen ───
  // Top & bottom double lines
  gOled->drawLine(0, 0, 127, 0, OLED_TEXT_COLOR);
  gOled->drawLine(0, 2, 127, 2, OLED_TEXT_COLOR);
  gOled->drawLine(0, 61, 127, 61, OLED_TEXT_COLOR);
  gOled->drawLine(0, 63, 127, 63, OLED_TEXT_COLOR);

  // Main title — big centered
  gOled->setTextSize(2);
  gOled->setCursor(14, 10);
  gOled->print("DROWSY");

  // Subtitle
  gOled->setTextSize(1);
  gOled->setCursor(14, 30);
  gOled->print("Driver Monitor v2");

  // Eye icons on sides
  drawEyeIcon(gOled, 16, 48, true);
  drawEyeIcon(gOled, 112, 48, true);

  // Bottom centered text
  gOled->setCursor(34, 44);
  gOled->print("STARTING...");

  // Animated loading dots
  uint8_t dotPhase = ((nowMs - _bootMs) / 300) % 4;
  for (uint8_t i = 0; i < dotPhase; i++) {
    gOled->fillCircle(48 + i * 10, 54, 2, OLED_TEXT_COLOR);
  }
#endif
}

void OledStatusDisplay::drawConnecting(uint32_t nowMs, const OledStatusSnapshot& snapshot,
                                       bool espReady, bool piReady) {
#if OLED_ENABLED
  if (gOled == nullptr) return;

  // ─── Header ───
  drawHeaderLine("  KET NOI HE THONG");

  // ─── WiFi icon + ESP32 status ───
  drawWifiIcon(gOled, 2, 13, espReady);
  gOled->setCursor(12, 13);
  gOled->print("ESP32: ");
  if (espReady) {
    gOled->print(snapshot.espIp);
    drawCheck(gOled, 120, 13);
  } else {
    // Animated dots
    uint8_t dotPhase = ((nowMs / 400) % 4);
    gOled->print("dang ket noi");
    for (uint8_t i = 0; i < dotPhase; i++) {
      gOled->print(".");
    }
  }

  // ─── Pi status ───
  drawWifiIcon(gOled, 2, 25, piReady);
  gOled->setCursor(12, 25);
  gOled->print("Pi:    ");
  if (piReady && snapshot.piIpKnown) {
    gOled->print(snapshot.piIp);
    drawCheck(gOled, 120, 25);
  } else {
    uint8_t dotPhase = ((nowMs / 400 + 1) % 4);
    gOled->print("dang ket noi");
    for (uint8_t i = 0; i < dotPhase; i++) {
      gOled->print(".");
    }
  }

  // ─── MQTT status ───
  gOled->setCursor(12, 37);
  gOled->print("MQTT:  ");
  if (snapshot.mqttReady) {
    gOled->print("da ket noi");
    drawCheck(gOled, 120, 37);
  } else {
    uint8_t dotPhase = ((nowMs / 400 + 2) % 4);
    gOled->print("cho");
    for (uint8_t i = 0; i < dotPhase; i++) {
      gOled->print(".");
    }
  }

  // ─── Status message at bottom ───
  gOled->setCursor(0, 49);
  if (espReady && !piReady) {
    gOled->print("  Cho Raspberry Pi...");
  } else if (!espReady && piReady) {
    gOled->print("  Cho ESP32 WiFi...");
  } else if (!espReady && !piReady) {
    gOled->print("  Dang ket noi WiFi...");
  }

  // ─── Animated spinner bar at very bottom ───
  int spinnerX = ((nowMs / 50) % 108);
  gOled->fillRect(spinnerX, 60, 20, 3, OLED_TEXT_COLOR);
#endif
}

void OledStatusDisplay::drawCalibration(uint32_t nowMs, const OledStatusSnapshot& snapshot,
                                        uint8_t pct) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  (void)snapshot;

  // ─── Header ───
  drawHeaderLine(" CALIB: NHIN THANG");

  // ─── Big centered percentage ───
  gOled->setTextSize(2);
  int xPos = (pct >= 100) ? 36 : ((pct >= 10) ? 40 : 48);
  gOled->setCursor(xPos, 14);
  gOled->print(static_cast<int>(pct));
  gOled->print("%");
  gOled->setTextSize(1);

  // ─── Eye icon ───
  bool eyeBlink = ((nowMs / 1500) % 3) == 0;
  drawEyeIcon(gOled, 10, 22, !eyeBlink);
  drawEyeIcon(gOled, 108, 22, !eyeBlink);

  // ─── Timer text ───
  uint32_t remainSec = ((100 - pct) * 5) / 100;
  if (remainSec > 5) remainSec = 5;
  gOled->setCursor(24, 34);
  gOled->print("Con lai: ");
  gOled->print(static_cast<int>(remainSec));
  gOled->print("s");

  // ─── Instruction ───
  gOled->setCursor(8, 44);
  gOled->print("Giu mat nhin thang");

  // ─── Progress bar at bottom ───
  drawProgressBar(4, 54, 120, 8, pct);
#endif
}

void OledStatusDisplay::drawActive(uint32_t nowMs, const OledStatusSnapshot& snapshot) {
#if OLED_ENABLED
  if (gOled == nullptr) return;

  // ─── Header ───
  drawHeaderLine("  DANG NHAN DIEN");

  // ─── Big status icon centered ───
  drawStatusIcon(56, 16, 0);  // Safe check icon

  // ─── Main text ───
  gOled->setCursor(28, 30);
  gOled->print("AN TOAN");

  // ─── Pi IP (1 line only) ───
  gOled->setCursor(4, 44);
  gOled->print("Pi:");
  if (snapshot.piIpKnown) {
    gOled->print(snapshot.piIp);
  } else {
    gOled->print("---");
  }

  // ─── Active indicator — pulsing dot ───
  bool pulse = ((nowMs / 500) % 2) == 0;
  if (pulse) {
    gOled->fillCircle(120, 44, 3, OLED_TEXT_COLOR);
  } else {
    gOled->drawCircle(120, 44, 3, OLED_TEXT_COLOR);
  }

  // ─── Bottom bar — full ───
  drawProgressBar(4, 56, 120, 6, 100);
#endif
}

void OledStatusDisplay::drawDrowsyAlert(uint32_t nowMs, const OledStatusSnapshot& snapshot) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  (void)snapshot;

  bool flashOn = ((nowMs / 250) % 2) == 0;

  if (flashOn) {
    // ─── Inverted flash for maximum attention ───
    gOled->fillRect(0, 0, 128, 64, OLED_TEXT_COLOR);
    gOled->setTextColor(0);  // Black text on white background

    gOled->setTextSize(2);
    gOled->setCursor(4, 4);
    gOled->print("!! CANH ");
    gOled->setCursor(4, 22);
    gOled->print("   BAO !!");

    gOled->setTextSize(1);
    gOled->setCursor(4, 44);
    gOled->print("BAN DANG NGU GAT!");

    gOled->setCursor(4, 54);
    gOled->print("TAP TRUNG LAI XE!");

    gOled->setTextColor(OLED_TEXT_COLOR);  // Restore
  } else {
    // ─── Normal frame with warning ───
    drawWarningTriangle(gOled, 64, 16, 12);

    gOled->setTextSize(1);
    gOled->setCursor(14, 34);
    gOled->print("BAN DANG NGU GAT!");

    gOled->setCursor(10, 46);
    gOled->print("TAP TRUNG LAI XE!");

    // Flashing border
    gOled->drawRect(0, 0, 128, 64, OLED_TEXT_COLOR);
    gOled->drawRect(1, 1, 126, 62, OLED_TEXT_COLOR);
  }
#endif
}

void OledStatusDisplay::drawRestWarning(uint32_t nowMs, const OledStatusSnapshot& snapshot) {
#if OLED_ENABLED
  if (gOled == nullptr) return;
  (void)snapshot;

  bool flashOn = ((nowMs / 500) % 2) == 0;

  // ─── Double border ───
  gOled->drawRect(0, 0, 128, 64, OLED_TEXT_COLOR);
  gOled->drawRect(2, 2, 124, 60, OLED_TEXT_COLOR);

  // ─── Warning icon ───
  drawWarningTriangle(gOled, 64, 12, 8);

  // ─── Message ───
  gOled->setTextSize(1);
  gOled->setCursor(10, 26);
  gOled->print("BAN QUA MET MOI!");

  gOled->setCursor(6, 38);
  gOled->print("HAY DUNG LAI NGHI!");

  if (flashOn) {
    gOled->setCursor(18, 50);
    gOled->print("!! NGHI NGOI !!");
  }
#endif
}

// ═════════════════════════════════════════════════════════════
// Main frame dispatcher
// ═════════════════════════════════════════════════════════════

void OledStatusDisplay::drawFrame(uint32_t nowMs, const OledStatusSnapshot& snapshot) {
#if !OLED_ENABLED
  (void)nowMs;
  (void)snapshot;
  return;
#else
  if (!_available || gOled == nullptr) return;

  const bool bootSplash = ((nowMs - _bootMs) < OLED_BOOT_SPLASH_MS);
  const bool espWifiReady = snapshot.wifiConnected && snapshot.espIpKnown;
  const bool piWifiReady = snapshot.piLinkReady && snapshot.piIpKnown;
  const bool wifiSyncReady = espWifiReady && piWifiReady;

  if (!wifiSyncReady) {
    if (_connectingSinceMs == 0) _connectingSinceMs = nowMs;
  } else {
    _connectingSinceMs = 0;
  }

  const bool robotMode = (!wifiSyncReady) && (_connectingSinceMs > 0) &&
                         (nowMs - _connectingSinceMs >= OLED_ROBOT_MODE_AFTER_MS);
  const bool robotPhase = ((nowMs / OLED_ROBOT_SWAP_MS) % 2U) != 0U;
  const uint32_t blinkDivMs = (OLED_ROBOT_SWAP_MS / 2U) > 0U ? (OLED_ROBOT_SWAP_MS / 2U) : 1U;
  const bool robotAltFrame = ((nowMs / blinkDivMs) % 2U) != 0U;
  const bool showRobotPage = robotMode && robotPhase;

  const uint8_t pct = snapshot.armed ? 100 : (snapshot.progressPct > 100 ? 100 : snapshot.progressPct);

  gOled->clearDisplay();
  gOled->setTextColor(OLED_TEXT_COLOR);
  gOled->setTextSize(OLED_FONT_SCALE);

  // ─── Determine which screen to show ───
  if (bootSplash) {
    drawBootSplash(nowMs);
  } else if (showRobotPage) {
    // Robot page is visual-only: cute waiting animation
    drawRobotFace(gOled, robotAltFrame);
    // Add subtle text below robot
    gOled->setCursor(22, 54);
    gOled->print("Dang cho ket noi");
  } else if (!wifiSyncReady) {
    drawConnecting(nowMs, snapshot, espWifiReady, piWifiReady);
  } else if (snapshot.restWarning) {
    drawRestWarning(nowMs, snapshot);
  } else if (snapshot.drowsyAlert) {
    drawDrowsyAlert(nowMs, snapshot);
  } else if (snapshot.armed) {
    drawActive(nowMs, snapshot);
  } else if (!snapshot.progressFromPi) {
    // Waiting for Pi data sync
    drawHeaderLine("  DONG BO DU LIEU");
    gOled->setCursor(4, 16);
    gOled->print("Cho du lieu tu Pi...");
    uint8_t dotPhase = ((nowMs / 400) % 4);
    for (uint8_t i = 0; i < dotPhase; i++) {
      gOled->fillCircle(40 + i * 12, 35, 2, OLED_TEXT_COLOR);
    }
    gOled->setCursor(12, 48);
    gOled->print("He thong san sang");
    // Spinner bar
    int spinnerX = ((nowMs / 50) % 108);
    gOled->fillRect(spinnerX, 58, 20, 4, OLED_TEXT_COLOR);
  } else {
    // Calibration: look straight 5s
    drawCalibration(nowMs, snapshot, pct);
  }

  gOled->display();
#endif
}
