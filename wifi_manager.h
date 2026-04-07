// #ifndef WIFI_MANAGER_H
// #define WIFI_MANAGER_H

// #include <Arduino.h>
// #include <Preferences.h>
// #include <WebServer.h>
// #include <WiFi.h>

// class WifiManager {
// public:
//   enum WifiState : uint8_t {
//     WIFI_DISCONNECTED = 0,
//     WIFI_CONNECTING = 1,
//     WIFI_CONNECTED = 2,
//   };

//   // NEW: flow state machine
//   enum FlowState : uint8_t {
//     FLOW_BOOT = 0,
//     FLOW_STA_CONNECT,
//     FLOW_PORTAL,
//     FLOW_RECONNECT,
//   };

//   struct Config {
//     uint32_t retryIntervalMs = 1500;
//     uint32_t connectTimeoutMs = 8000;
//     uint32_t portalFallbackMs = 15000;
//     uint32_t internetCheckIntervalMs = 7000;

//     // NEW
//     bool requireInternet = false;
//     const char *healthHost = "192.168.0.163";
//     uint16_t healthPort = 1883;

//     const char *nvsNamespace = "wifi_cfg";
//     const char *apPassword = "Drowsy@2026!";
//   };

//   explicit WifiManager(const Config &config = Config());

//   void begin(const char *apPrefix = "DrowsySetup");
//   void tick(uint32_t nowMs);

//   bool isConnected() const;
//   bool hasCredentials() const;
//   bool portalActive() const;

//   String connectedSsid() const;
//   IPAddress localIP() const;

//   void clearCredentials();

//   // Force-open AP config portal without clearing stored credentials.
//   // Used by: long-press button (Method A), remote MQTT command (Method B).
//   void openPortal();

//   // NEW
//   FlowState flowState() const { return _flowState; }

// private:
//   Config _cfg;
//   Preferences _prefs;
//   WebServer _server;

//   String _ssid;
//   String _password;
//   String _apPrefix;
//   String _apSsid;

//   bool _prefsReady = false;
//   bool _portalRunning = false;
//   bool _wasConnected = false;
//   uint32_t _lastConnectedMs = 0;
//   WifiState _wifiState = WIFI_DISCONNECTED;

//   // NEW
//   FlowState _flowState = FLOW_BOOT;

//   uint32_t _wifiConnectStartMs = 0;
//   uint32_t _nextWifiRetryMs = 0;
//   uint32_t _wifiBackoffMs = 1000;
//   uint32_t _lastInternetCheckMs = 0;

//   static constexpr uint32_t WIFI_BACKOFF_MIN_MS = 1000;
//   static constexpr uint32_t WIFI_BACKOFF_MAX_MS = 10000;

//   void loadCredentials();
//   void saveCredentials(const String &ssid, const String &password);
//   void beginConnect(uint32_t nowMs);
//   bool hasInternet();
//   void startPortal();
//   void stopPortal();
//   void setupRoutes();

//   void handleRoot();
//   void handleSave();
//   void handleStatus();
// };

// #endif
#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <Arduino.h>
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
    uint32_t connectTimeoutMs = 8000;
    uint32_t portalFallbackMs = 15000;
    uint32_t internetCheckIntervalMs = 7000;

    // NEW
    bool requireInternet = false;
    const char *healthHost = "192.168.0.163";
    uint16_t healthPort = 1883;

    const char *nvsNamespace = "wifi_cfg";
    const char *apPassword = "Drowsy@2026!";
  };

  explicit WifiManager(const Config &config = Config());

  void begin(const char *apPrefix = "DrowsySetup");
  void tick(uint32_t nowMs);

  bool isConnected() const;
  bool hasCredentials() const;
  bool portalActive() const;

  String connectedSsid() const;
  IPAddress localIP() const;

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

  String _ssid;
  String _password;
  String _apPrefix;
  String _apSsid;

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
  uint32_t _lastInternetCheckMs = 0;

  static constexpr uint32_t WIFI_BACKOFF_MIN_MS = 1000;
  static constexpr uint32_t WIFI_BACKOFF_MAX_MS = 10000;

  void loadCredentials();
  void saveCredentials(const String &ssid, const String &password);
  void beginConnect(uint32_t nowMs);
  bool hasInternet();
  void startPortal();
  void stopPortal();
  void setupRoutes();
  void emitPiWifiCredentials();
  void emitPiWifiConnected();

  void handleRoot();
  void handleSave();
  void handleStatus();
};

#endif
