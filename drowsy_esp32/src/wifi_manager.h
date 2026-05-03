#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <Arduino.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

class WifiManager {
public:
  enum WifiState : uint8_t {
    WIFI_DISCONNECTED = 0,
    WIFI_CONNECTING = 1,
    WIFI_CONNECTED = 2,
  };

  // NEW: flow state machine
  enum FlowState : uint8_t {
    FLOW_BOOT = 0,
    FLOW_STA_CONNECT,
    FLOW_PORTAL,
    FLOW_RECONNECT,
  };

  struct Config {
    uint32_t retryIntervalMs = 1500;
    uint32_t connectTimeoutMs = 6500;
    uint32_t portalFallbackMs = 15000;
    uint32_t internetCheckIntervalMs = 7000;

    // NEW
    bool requireInternet = false;
    const char *healthHost = "raspberrypi.local";
    uint16_t healthPort = 1883;
    // Keep setup AP visible at all times so users can reconfigure WiFi
    // without pressing BOOT/reset button.
    bool alwaysOnPortal = true;
    // Rotate AP SSID per boot session to reduce captive-portal cache issues.
    bool rotateApSsidPerBoot = true;

    const char *nvsNamespace = "wifi_cfg";
    const char *apPassword = "Drowsy@2026!";
  };

  WifiManager();
  explicit WifiManager(const Config &config);

  void begin(const char *apPrefix = "DrowsySetup");
  void tick(uint32_t nowMs);

  bool isConnected() const;
  bool hasCredentials() const;
  bool portalActive() const;

  String connectedSsid() const;
  IPAddress localIP() const;
  void requestPiSync(uint32_t nowMs = 0);
  void notifyPiBridgeSeen(uint32_t nowMs = 0);
  bool isPiBridgeRecent(uint32_t nowMs = 0) const;

  void clearCredentials();

  // Force-open AP config portal without clearing stored credentials.
  // Used by: long-press button (Method A), remote MQTT command (Method B).
  void openPortal();

  // NEW
  FlowState flowState() const { return _flowState; }

private:
  Config _cfg;
  Preferences _prefs;
  WebServer _server;
  DNSServer _dns;

  String _ssid;
  String _password;
  String _apPrefix;
  String _apSsid;
  uint16_t _apSessionTag = 0;

  bool _prefsReady = false;
  bool _portalRunning = false;
  bool _wasConnected = false;
  uint32_t _lastConnectedMs = 0;
  WifiState _wifiState = WIFI_DISCONNECTED;

  // NEW
  FlowState _flowState = FLOW_BOOT;

  uint32_t _wifiConnectStartMs = 0;
  uint32_t _nextWifiRetryMs = 0;
  uint32_t _wifiBackoffMs = 1000;
  uint8_t _fastRetryLeft = 0;
  uint32_t _lastInternetCheckMs = 0;
  uint32_t _lastPiCredEmitMs = 0;
  uint32_t _lastPiConnectedEmitMs = 0;
  uint32_t _lastPiSyncRequestMs = 0;
  uint32_t _lastPiBridgeSeenMs = 0;
  uint32_t _captiveSuccessUntilMs = 0;
  IPAddress _captiveSuccessClientIp = IPAddress(0, 0, 0, 0);

  static constexpr uint32_t WIFI_BACKOFF_MIN_MS = 1000;
  static constexpr uint32_t WIFI_BACKOFF_MAX_MS = 10000;
  static constexpr uint32_t WIFI_FAST_RETRY_MS = 450;
  static constexpr uint8_t WIFI_FAST_RETRY_ATTEMPTS_BOOT = 4;
  static constexpr uint8_t WIFI_FAST_RETRY_ATTEMPTS_SAVE = 6;
  static constexpr uint32_t PI_CRED_EMIT_INTERVAL_MS = 3000;
  static constexpr uint32_t PI_CONNECTED_EMIT_INTERVAL_MS = 2500;
  static constexpr uint32_t PI_SYNC_REQUEST_GAP_MS = 1200;
  static constexpr uint32_t PI_CRED_MIN_GAP_MS = 500;   // FIX: 1200→500ms for faster retry
  static constexpr uint32_t PI_BRIDGE_FRESH_MS = 20000;
  static constexpr uint32_t CAPTIVE_SUCCESS_WINDOW_MS = 15000;
  static constexpr uint16_t CAPTIVE_DNS_PORT = 53;

  void loadCredentials();
  void saveCredentials(const String &ssid, const String &password);
  void beginConnect(uint32_t nowMs);
  bool hasInternet();
  void startPortal();
  void stopPortal();
  void setupRoutes();
  void emitPiWifiCredentials(bool force = false);
  void emitPiWifiConnected();
  void redirectToPortal();
  void handleCaptiveProbe();

  void handleRoot();
  void handleSave();
  void handleStatus();
  void handleScan();
};

#endif
