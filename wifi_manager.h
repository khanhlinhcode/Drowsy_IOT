#ifndef WIFI_MANAGER_H
#define WIFI_MANAGER_H

#include <Arduino.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

class WifiManager {
 public:
  struct Config {
    uint32_t retryIntervalMs = 1500;
    uint32_t connectTimeoutMs = 10000;
    uint32_t portalFallbackMs = 15000;
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
  bool _connecting = false;
  bool _wasConnected = false;
  uint32_t _connectSinceMs = 0;
  uint32_t _nextConnectTryMs = 0;
  uint32_t _lastConnectedMs = 0;

  void loadCredentials();
  void saveCredentials(const String& ssid, const String& password);
  void beginConnect(uint32_t nowMs);
  void startPortal();
  void stopPortal();
  void setupRoutes();

  void handleRoot();
  void handleSave();
  void handleStatus();
};

#endif

