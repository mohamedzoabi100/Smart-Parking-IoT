# 🅿️ Smart Parking IoT

> **Real-time parking monitoring and violation tracking using ESP32, Firebase, and Flutter.**

---

## 🎬 Demo Video

**▶️ [Watch the full demo here](https://drive.google.com/file/d/1qJlrlZBkcDG9mJDVStmBfwjteGEa_WNK/view?usp=drive_link)**

---

## 📖 Overview

Smart Parking System is an IoT solution that tracks parking events in real time using an **ESP32 microcontroller** with LED indicators, syncs data to **Firebase Realtime Database**, and displays live analytics through a **Flutter mobile app**.

---

## ✨ Features

- **Real-time Event Detection** — 4 event types detected every 5 seconds with LED color indicators (🟢 Green / 🔴 Red / 🔵 Blue)
- **Cloud Sync** — Auto-upload to Firebase with a 1000-event offline buffer
- **Live Dashboard** — Pie charts (event distribution), line graphs (25-min occupancy history), statistics (avg. parking time, success rates), real-time event feed
- **Car Tracking** — Live view of currently parked cars, completed sessions, and recent events

---

## 📱 App Screenshots

| Event Analytics | Car Tracking | Hardware Setup |
|---|---|---|
| ![Event Analytics](screenshots/analytics.jpg) | ![Car Tracking](screenshots/tracking.jpg) | ![Hardware](screenshots/hardware.jpg) |

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Microcontroller | ESP32 (Arduino) |
| Mobile App | Flutter (Dart) |
| Cloud Database | Firebase Realtime Database |
| Communication | WiFi (ESP32 → Firebase) |
| LED Indicators | Green / Red / Blue |

---

## 🗂️ Project Structure

```
smart_parking/
├── lib/               # Flutter app source code (main.dart)
├── wifimanager.ino    # ESP32 Arduino firmware
├── android/           # Android build files
├── ios/               # iOS build files
└── pubspec.yaml       # Flutter dependencies
```

---

## 🚀 How It Works

1. **ESP32** detects parking events via sensors and lights the appropriate LED
2. Events are sent to **Firebase RTDB** in real time (buffered offline if no WiFi)
3. **Flutter app** listens to Firebase and updates the live dashboard instantly

---

## 👨‍💻 Author

- **Mohammad Zoabi** — [github.com/mohamedzoabi100](https://github.com/mohamedzoabi100)

*Technion — Israel Institute of Technology, Summer 2025*
*Instructor: Ido Ram*
