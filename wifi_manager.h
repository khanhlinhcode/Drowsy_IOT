#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <Arduino.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

class WifiManager {
 public:
  // FIX: explicit WiFi state machine to avoid stuck/false connected transitions.
  enum WifiState : uint8_t {
    WIFI_DISCONNECTED = 0,
    WIFI_CONNECTING = 1,
    WIFI_CONNECTED = 2,
  };

  struct Config {
    uint32_t retryIntervalMs = 1500;
    // CRITICAL: bound connecting window to break stuck CONNECTING state.
    uint32_t connectTimeoutMs = 8000;
    uint32_t portalFallbackMs = 15000;
    // FIX: periodic lightweight internet health probe interval.
    uint32_t internetCheckIntervalMs = 7000;
    const char* nvsNamespace = "wifi_cfg";
    const char* apPassword = "12345678";
  };

  explicit WifiManager(const Config& config = Config());

  void begin(const char* apPrefix = "DrowsySetup");
  void tick(uint32_t nowMs);

  bool isConnected() const;
  bool hasCredentials() const;
  bool portalActive() const;

  String connectedSsid() const;
  IPAddress localIP() const;

  void clearCredentials();

 private:
  Config _cfg;
  Preferences _prefs;
  WebServer _server;

  String _ssid;
  String _password;
  String _apPrefix;
  String _apSsid;

  bool _prefsReady = false;
  bool _portalRunning = false;
  bool _wasConnected = false;
  uint32_t _lastConnectedMs = 0;
  WifiState _wifiState = WIFI_DISCONNECTED;
  uint32_t _wifiConnectStartMs = 0;
  uint32_t _nextWifiRetryMs = 0;
  uint32_t _wifiBackoffMs = 1000;
  uint32_t _lastInternetCheckMs = 0;

  // FIX: exponential reconnect backoff bounds.
  static constexpr uint32_t WIFI_BACKOFF_MIN_MS = 1000;
  static constexpr uint32_t WIFI_BACKOFF_MAX_MS = 10000;

  void loadCredentials();
  void saveCredentials(const String& ssid, const String& password);
  void beginConnect(uint32_t nowMs);
  bool hasInternet();
  void startPortal();
  void stopPortal();
  void setupRoutes();

  void handleRoot();
  void handleSave();
  void handleStatus();
};

#endif
