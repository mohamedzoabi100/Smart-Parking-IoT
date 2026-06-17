import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'dart:math' as math;

// Data Models
class ParkingEvent {
  final String id;
  final DateTime timestamp;
  final int eventType; // 1-4
  final String carId;
  final String ledColor;
  final bool isCorrect;
  // NEW: Buffer support fields
  final DateTime? realTimestamp;  // Original ESP32 timestamp
  final bool isBuffered;          // Was this event buffered?
  final DateTime? syncedAt;       // When was it synced to Firebase?

  ParkingEvent({
    required this.id,
    required this.timestamp,
    required this.eventType,
    required this.carId,
    required this.ledColor,
    required this.isCorrect,
    // NEW: Buffer fields
    this.realTimestamp,
    this.isBuffered = false,
    this.syncedAt,
  });

  factory ParkingEvent.fromRTDB(String key, Map<dynamic, dynamic> data) {
    try {
      DateTime timestamp = _parseTimestamp(data['timestamp']);
      
      // NEW: Parse buffer-related fields
      DateTime? realTimestamp;
      if (data['real_timestamp'] != null) {
        try {
          int realTimestampValue = data['real_timestamp'];
          realTimestamp = DateTime.fromMillisecondsSinceEpoch(realTimestampValue * 1000);
        } catch (e) {
          print('Error parsing real_timestamp: $e');
        }
      }
      
      DateTime? syncedAt;
      if (data['synced_at'] != null) {
        try {
          String syncedAtStr = data['synced_at'].toString();
          if (syncedAtStr.length > 10) {
            syncedAt = DateTime.fromMillisecondsSinceEpoch(int.parse(syncedAtStr));
          } else {
            syncedAt = DateTime.fromMillisecondsSinceEpoch(int.parse(syncedAtStr) * 1000);
          }
        } catch (e) {
          print('Error parsing synced_at: $e');
        }
      }
      
      return ParkingEvent(
        id: key,
        timestamp: timestamp,
        eventType: data['event_type'] ?? 1,
        carId: data['car_id'] ?? 'UNKNOWN',
        ledColor: data['led_color'] ?? 'gray',
        isCorrect: data['is_correct'] ?? false,
        // NEW: Buffer fields
        realTimestamp: realTimestamp,
        isBuffered: data['is_buffered'] ?? false,
        syncedAt: syncedAt,
      );
    } catch (e) {
      print('Error parsing RTDB data: $e');
      return ParkingEvent(
        id: key,
        timestamp: DateTime.now(),
        eventType: 1,
        carId: 'ERROR',
        ledColor: 'gray',
        isCorrect: false,
      );
    }
  }

  static DateTime _parseTimestamp(dynamic timestampData) {
    if (timestampData == null) return DateTime.now();
    
    try {
      if (timestampData is String) {
        int? timestampInt = int.tryParse(timestampData);
        if (timestampInt != null) {
          return _parseTimestampInt(timestampInt);
        }
        return DateTime.tryParse(timestampData) ?? DateTime.now();
      } else if (timestampData is int) {
        return _parseTimestampInt(timestampData);
      }
    } catch (e) {
      print('Error parsing timestamp: $e');
    }
    
    return DateTime.now();
  }

  static DateTime _parseTimestampInt(int timestamp) {
    DateTime epochStart2020 = DateTime(2020, 1, 1);
    int epoch2020Ms = epochStart2020.millisecondsSinceEpoch;
    
    if (timestamp > epoch2020Ms) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else {
      DateTime now = DateTime.now();
      Duration relativeTime = Duration(milliseconds: timestamp);
      
      if (relativeTime.inHours > 24) {
        relativeTime = Duration(minutes: timestamp ~/ 60000);
        if (relativeTime.inHours > 24) {
          relativeTime = Duration(hours: 1);
        }
      }
      
      return now.subtract(relativeTime);
    }
  }

  String get description {
    switch (eventType) {
      case 1: return "Car enters correct parking";
      case 2: return "Car enters wrong parking";
      case 3: return "Car exits correct parking";
      case 4: return "Car exits wrong parking";
      default: return "Unknown event";
    }
  }
  
  // NEW: Use real timestamp if available, otherwise fall back to regular timestamp
  DateTime get displayTimestamp => realTimestamp ?? timestamp;
  
  // NEW: Helper to check if this event was significantly delayed
  bool get isDelayedSync {
    if (!isBuffered || syncedAt == null || realTimestamp == null) return false;
    Duration delay = syncedAt!.difference(realTimestamp!);
    return delay.inMinutes > 5; // Consider delayed if more than 5 minutes
  }
}

class CarSession {
  final String carId;
  final DateTime entryTime;
  DateTime? exitTime;
  final bool enteredCorrectly;
  final bool wasBuffered;       // NEW: Track if session had buffered events
  
  CarSession({
    required this.carId,
    required this.entryTime,
    required this.enteredCorrectly,
    this.exitTime,
    this.wasBuffered = false,   // NEW: Buffer tracking
  });
  
  Duration? get sessionDuration {
    if (exitTime != null) {
      return exitTime!.difference(entryTime);
    }
    return null;
  }
  
  Duration get currentDuration {
    Duration duration = DateTime.now().difference(entryTime);
    
    if (duration.inDays > 7) {
      return Duration(minutes: DateTime.now().minute % 60 + 1);
    }
    
    return duration;
  }
  
  bool get isActive => exitTime == null;
}

// Data point for parking occupancy over time
class ParkingDataPoint {
  final DateTime time;
  final int carCount;
  
  ParkingDataPoint({required this.time, required this.carCount});
}

class ParkingFirebaseService {
  static final DatabaseReference _database = FirebaseDatabase.instance.ref();
  
  static Stream<List<ParkingEvent>> getParkingEventsStream() {
    return _database
        .child('parking_events')
        .orderByKey()
        .onValue  // Removed limitToLast(100) to get all events
        .map((event) {
          try {
            List<ParkingEvent> events = [];
            
            if (event.snapshot.value != null) {
              Map<dynamic, dynamic> data = event.snapshot.value as Map<dynamic, dynamic>;
              
              List<MapEntry<String, dynamic>> entries = [];
              data.forEach((key, value) {
                if (value != null && value is Map<dynamic, dynamic>) {
                  entries.add(MapEntry(key.toString(), value));
                }
              });
              
              // NEW: Sort by real timestamp if available, otherwise by key
              entries.sort((a, b) {
                try {
                  // Try to sort by real_timestamp first
                  int? realTimestampA = a.value['real_timestamp'];
                  int? realTimestampB = b.value['real_timestamp'];
                  
                  if (realTimestampA != null && realTimestampB != null) {
                    return realTimestampB.compareTo(realTimestampA);
                  }
                  
                  // Fall back to sorting by key (which contains timestamp)
                  return b.key.compareTo(a.key);
                } catch (e) {
                  return b.key.compareTo(a.key);
                }
              });
              
              for (var entry in entries) {
                events.add(ParkingEvent.fromRTDB(entry.key, entry.value));
              }
            }
            
            return events;
          } catch (e) {
            print('Error processing RTDB events stream: $e');
            return <ParkingEvent>[];
          }
        });
  }
  
  static Future<void> clearAllEvents() async {
    try {
      await _database.child('parking_events').remove();
      print('All events cleared from RTDB');
    } catch (e) {
      print('Error clearing events: $e');
      rethrow;
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Parking IoT Dashboard',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        fontFamily: 'Roboto',
      ),
      home: ParkingDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ParkingDashboard extends StatefulWidget {
  @override
  _ParkingDashboardState createState() => _ParkingDashboardState();
}

class _ParkingDashboardState extends State<ParkingDashboard> 
    with TickerProviderStateMixin {
  
  late TabController _tabController;
  late Timer _chartUpdateTimer;
  
  // ValueNotifiers for targeted updates
  ValueNotifier<ParkingEvent?> currentEventNotifier = ValueNotifier(null);
  ValueNotifier<List<ParkingEvent>> recentEventsNotifier = ValueNotifier([]);
  ValueNotifier<Map<String, CarSession>> activeCarsNotifier = ValueNotifier({});
  ValueNotifier<List<CarSession>> completedSessionsNotifier = ValueNotifier([]);
  ValueNotifier<Map<String, dynamic>> eventStatsNotifier = ValueNotifier({});
  ValueNotifier<Map<String, dynamic>> carStatsNotifier = ValueNotifier({});
  ValueNotifier<List<ParkingDataPoint>> parkingChartDataNotifier = ValueNotifier([]);
  
  Map<int, List<int>> waitTimes = {1: [], 2: [], 3: [], 4: []};
  Map<int, int> waitCounters = {1: 0, 2: 0, 3: 0, 4: 0};
  int totalEventCount = 0;
  
  Map<String, CarSession> activeCars = {};
  List<CarSession> completedSessions = [];
  List<ParkingDataPoint> parkingChartData = [];
  
  // NEW: Buffer statistics
  int bufferedEventsCount = 0;
  int syncedEventsCount = 0;
  DateTime? lastSyncTime;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    
    // Initialize with current time and 0 cars
    _addParkingDataPoint();
    
    // Update chart every 30 seconds
    _chartUpdateTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _addParkingDataPoint();
    });
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    _chartUpdateTimer.cancel();
    currentEventNotifier.dispose();
    recentEventsNotifier.dispose();
    activeCarsNotifier.dispose();
    completedSessionsNotifier.dispose();
    eventStatsNotifier.dispose();
    carStatsNotifier.dispose();
    parkingChartDataNotifier.dispose();
    super.dispose();
  }
  
  void _addParkingDataPoint() {
    DateTime now = DateTime.now();
    int currentCarCount = activeCars.length;
    
    // Add new data point
    parkingChartData.add(ParkingDataPoint(time: now, carCount: currentCarCount));
    
    // Keep only last 50 data points (about 25 minutes at 30-second intervals)
    if (parkingChartData.length > 50) {
      parkingChartData.removeAt(0);
    }
    
    // Update notifier
    parkingChartDataNotifier.value = List.from(parkingChartData);
  }
  
  Map<String, dynamic> _calculateStats(List<ParkingEvent> events) {
    int greenEvents = events.where((e) => e.eventType == 1 || e.eventType == 3).length;
    int redEvents = events.where((e) => e.eventType == 2).length;
    int blueEvents = events.where((e) => e.eventType == 4).length;
    
    _updateWaitTimes(events);
    
    return {
      'green': greenEvents,
      'red': redEvents,
      'blue': blueEvents,
      'total': events.length,
      'waitTimes': _getAverageWaitTimes(),
    };
  }

  void _processNewData(List<ParkingEvent> events) {
    // Only update if data actually changed
    if (events.isNotEmpty && currentEventNotifier.value?.id != events.first.id) {
      currentEventNotifier.value = events.first;
    }
    
    // NEW: Update buffer statistics
    bufferedEventsCount = events.where((e) => e.isBuffered).length;
    syncedEventsCount = events.where((e) => e.syncedAt != null).length;
    
    var syncedEvents = events.where((e) => e.syncedAt != null);
    if (syncedEvents.isNotEmpty) {
      lastSyncTime = syncedEvents.first.syncedAt;
    }
    
    // Update recent events (removed 20 limit, newest first)
    List<ParkingEvent> sortedEvents = List.from(events);
    sortedEvents.sort((a, b) => b.displayTimestamp.compareTo(a.displayTimestamp));  // NEW: Use displayTimestamp
    
    if (!_listEquals(recentEventsNotifier.value, sortedEvents)) {
      recentEventsNotifier.value = sortedEvents;
    }
    
    // Update car tracking
    Map<String, dynamic> newEventStats = _calculateStats(events);
    Map<String, dynamic> newCarStats = _calculateCarStats(events);
    
    if (!_mapEquals(eventStatsNotifier.value, newEventStats)) {
      eventStatsNotifier.value = newEventStats;
    }
    
    if (!_mapEquals(carStatsNotifier.value, newCarStats)) {
      carStatsNotifier.value = newCarStats;
    }
    
    // Update active cars if changed
    if (!_mapEquals(activeCarsNotifier.value, activeCars)) {
      activeCarsNotifier.value = Map.from(activeCars);
    }
    
    // Update completed sessions if changed
    if (!_listEquals(completedSessionsNotifier.value, completedSessions)) {
      completedSessionsNotifier.value = List.from(completedSessions);
    }
  }
  
  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
  
  bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (K key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
  
Map<String, dynamic> _calculateCarStats(List<ParkingEvent> events) {
    // Always recalculate car sessions from scratch to handle buffered events correctly
    _updateCarSessions(events);
    
    List<CarSession> allCompletedSessions = List.from(completedSessions);
    allCompletedSessions.sort((a, b) => b.exitTime!.compareTo(a.exitTime!));
    
    // Calculate average duration including both completed and ongoing sessions
    // This ensures accurate calculations even when buffered events complete old sessions
    double avgDurationMinutes = 0.0;
    double totalMinutes = 0.0;
    int totalSessions = 0;
    
    // Add completed sessions (using real durations from displayTimestamp)
    for (CarSession session in allCompletedSessions) {
      Duration? duration = session.sessionDuration;
      if (duration != null) {
        totalMinutes += duration.inMinutes + (duration.inSeconds % 60) / 60.0;
        totalSessions++;
      }
    }
    
    // Add ongoing active sessions (current duration from displayTimestamp)
    for (CarSession session in activeCars.values) {
      Duration currentDuration = session.currentDuration;
      totalMinutes += currentDuration.inMinutes + (currentDuration.inSeconds % 60) / 60.0;
      totalSessions++;
    }
    
    if (totalSessions > 0) {
      avgDurationMinutes = totalMinutes / totalSessions;
    }
    
    return {
      'activeCars': activeCars.length,
      'completedSessions': allCompletedSessions.length,  // Updated count after buffered events
      'avgSessionMinutes': avgDurationMinutes,           // Recalculated average with real durations
      'totalSessions': allCompletedSessions.length + activeCars.length,  // Updated total
      'activeCarsDetails': activeCars,
      'recentCompletedSessions': allCompletedSessions,
    };
  }
  
  void _updateCarSessions(List<ParkingEvent> events) {
    // NEW: Sort events by display timestamp (real timestamp when available)
    List<ParkingEvent> chronologicalEvents = List.from(events);
    chronologicalEvents.sort((a, b) => a.displayTimestamp.compareTo(b.displayTimestamp));
    
    activeCars.clear();
    completedSessions.clear();
    
    for (ParkingEvent event in chronologicalEvents) {
      if (event.eventType == 1 || event.eventType == 2) {
        // Entry events
        if (!activeCars.containsKey(event.carId)) {
          activeCars[event.carId] = CarSession(
            carId: event.carId,
            entryTime: event.displayTimestamp,   // NEW: Use displayTimestamp
            enteredCorrectly: event.eventType == 1,
            wasBuffered: event.isBuffered,       // NEW: Track if buffered
          );
        }
      } else if (event.eventType == 3 || event.eventType == 4) {
        // Exit events
        if (activeCars.containsKey(event.carId)) {
          CarSession session = activeCars[event.carId]!;
          
          // Create a new CarSession with exit time for completed sessions
          CarSession completedSession = CarSession(
            carId: session.carId,
            entryTime: session.entryTime,
            enteredCorrectly: session.enteredCorrectly,
            exitTime: event.displayTimestamp,    // NEW: Use displayTimestamp
            wasBuffered: session.wasBuffered || event.isBuffered,  // NEW: Track if any event was buffered
          );
          
          completedSessions.insert(0, completedSession);
          activeCars.remove(event.carId);
        }
      }
    }
  }
  
  void _updateWaitTimes(List<ParkingEvent> events) {
    if (events.length <= totalEventCount) return;
    
    // Sort chronologically for proper wait time calculation (using displayTimestamp)
    List<ParkingEvent> sortedEvents = List.from(events);
    sortedEvents.sort((a, b) => a.displayTimestamp.compareTo(b.displayTimestamp));  // NEW: Use displayTimestamp
    
    // Process only new events
    for (int i = totalEventCount; i < sortedEvents.length; i++) {
      ParkingEvent event = sortedEvents[i];
      
      // Increment all counters for each new event
      waitCounters[1] = waitCounters[1]! + 1;
      waitCounters[2] = waitCounters[2]! + 1;
      waitCounters[3] = waitCounters[3]! + 1;
      waitCounters[4] = waitCounters[4]! + 1;
      
      // Record wait time for this event type and reset its counter
      int eventType = event.eventType;
      waitTimes[eventType]!.add(waitCounters[eventType]!);
      waitCounters[eventType] = 0;
      
      print('Wait time updated for event type $eventType: ${waitCounters[eventType]} events since last occurrence');
    }
    
    totalEventCount = events.length;
  }
  
  Map<int, double> _getAverageWaitTimes() {
    Map<int, double> averages = {};
    
    for (int eventType = 1; eventType <= 4; eventType++) {
      List<int> times = waitTimes[eventType]!;
      if (times.isNotEmpty) {
        double average = times.reduce((a, b) => a + b) / times.length;
        averages[eventType] = average;
      } else {
        averages[eventType] = 0.0;
      }
    }
    
    return averages;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.local_parking),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Smart Parking IoT',
                style: Theme.of(context).textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // NEW: Buffer status indicator
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: bufferedEventsCount > 0 ? Colors.orange.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: bufferedEventsCount > 0 ? Colors.orange.withOpacity(0.3) : Colors.green.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: bufferedEventsCount > 0 ? Colors.orange : Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 4),
                  Text(
                    bufferedEventsCount > 0 ? 'Buffer: $bufferedEventsCount' : 'ESP32',
                    style: TextStyle(
                      color: bufferedEventsCount > 0 ? Colors.orange : Colors.green,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: Icon(Icons.analytics),
              text: 'Event Analytics',
            ),
            Tab(
              icon: Icon(Icons.directions_car),
              text: 'Car Tracking',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Data processor - StreamBuilder that only processes data, doesn't rebuild UI
          StreamBuilder<List<ParkingEvent>>(
            stream: ParkingFirebaseService.getParkingEventsStream(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Connecting to Firebase RTDB...'),
                      SizedBox(height: 8),
                      Text(
                        'Waiting for ESP32 data...',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                );
              }
              
              if (snapshot.hasError) {
                return Center(
                  child: Card(
                    margin: EdgeInsets.all(16),
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error, color: Colors.red, size: 64),
                          SizedBox(height: 16),
                          Text('Firebase RTDB Connection Error', style: Theme.of(context).textTheme.headlineSmall),
                          SizedBox(height: 8),
                          Text('${snapshot.error}', textAlign: TextAlign.center),
                          SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () => setState(() {}),
                            child: Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              
              // Process data but don't return UI widgets
              List<ParkingEvent> events = snapshot.data ?? [];
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _processNewData(events);
              });
              
              return SizedBox.shrink(); // No UI from StreamBuilder
            },
          ),
          
          // Live Status - targeted update with ValueListenableBuilder
          ValueListenableBuilder<ParkingEvent?>(
            valueListenable: currentEventNotifier,
            builder: (context, currentEvent, child) {
              return _buildLiveStatusSection(currentEvent);
            },
          ),
          
          // NEW: Buffer Status Section
          if (bufferedEventsCount > 0 || syncedEventsCount > 0)
            _buildBufferStatusSection(),
          
          // Main content tabs
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildEventAnalyticsTab(),
                _buildCarTrackingTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  // NEW: Buffer status section
  Widget _buildBufferStatusSection() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12),
      color: Colors.orange[50],
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange[700]),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Buffer System Status',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange[800]),
                  ),
                  Text(
                    'Buffered events: $bufferedEventsCount | '
                    'Synced events: $syncedEventsCount' +
                    (lastSyncTime != null ? ' | Last sync: ${lastSyncTime!.toString().substring(11, 19)}' : ''),
                    style: TextStyle(fontSize: 12, color: Colors.orange[700]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildLiveStatusSection(ParkingEvent? currentEvent) {
    return Card(
      margin: EdgeInsets.all(12),
      elevation: 1,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: currentEvent != null 
                  ? (currentEvent.ledColor == "green" ? Colors.green : 
                     currentEvent.ledColor == "red" ? Colors.red : Colors.blue)
                  : Colors.grey,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.circle, color: Colors.white, size: 16),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentEvent?.description ?? "Waiting for ESP32 data...",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (currentEvent != null)
                    Row(
                      children: [
                        Text(
                          "Car: ${currentEvent.carId} • LED: ${currentEvent.ledColor.toUpperCase()}",
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        // NEW: Buffer indicators
                        if (currentEvent.isBuffered) ...[
                          SizedBox(width: 8),
                          Icon(Icons.storage, size: 12, color: Colors.orange),
                          Text(' Buffered', style: TextStyle(color: Colors.orange, fontSize: 10)),
                        ],
                        if (currentEvent.isDelayedSync) ...[
                          SizedBox(width: 8),
                          Icon(Icons.schedule, size: 12, color: Colors.red),
                          Text(' Delayed', style: TextStyle(color: Colors.red, fontSize: 10)),
                        ],
                      ],
                    ),
                ],
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility, size: 12, color: Colors.blue),
                  SizedBox(width: 4),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.blue,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildEventAnalyticsTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        children: [
          // Charts section - updates when eventStats change
          ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: eventStatsNotifier,
            builder: (context, stats, child) {
              return _buildChartsSection(stats);
            },
          ),
          SizedBox(height: 16),
          // Recent events section - updates when events change
          ValueListenableBuilder<List<ParkingEvent>>(
            valueListenable: recentEventsNotifier,
            builder: (context, events, child) {
              return _buildRecentEventsSection(events);
            },
          ),
          SizedBox(height: 16),
          // Control section - updates when eventStats change for event count
          ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: eventStatsNotifier,
            builder: (context, stats, child) {
              return _buildControlSection(stats['total'] ?? 0);
            },
          ),
          SizedBox(height: 80),
        ],
      ),
    );
  }
  
  Widget _buildCarTrackingTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        children: [
          // Car summary cards - updates when carStats change
          ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: carStatsNotifier,
            builder: (context, carStats, child) {
              return _buildCarSummaryCards(carStats);
            },
          ),
          SizedBox(height: 16),
          // Parking occupancy chart - NEW
          ValueListenableBuilder<List<ParkingDataPoint>>(
            valueListenable: parkingChartDataNotifier,
            builder: (context, chartData, child) {
              return _buildParkingOccupancyChart(chartData);
            },
          ),
          SizedBox(height: 16),
          // Active cars section - updates when activeCars change
          ValueListenableBuilder<Map<String, CarSession>>(
            valueListenable: activeCarsNotifier,
            builder: (context, activeCars, child) {
              return _buildActiveCarsSection(activeCars);
            },
          ),
          SizedBox(height: 16),
          // Session history section - updates when completedSessions change
          ValueListenableBuilder<List<CarSession>>(
            valueListenable: completedSessionsNotifier,
            builder: (context, recentSessions, child) {
              return _buildSessionHistorySection(recentSessions);
            },
          ),
          SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildParkingOccupancyChart(List<ParkingDataPoint> chartData) {
    if (chartData.isEmpty) {
      return Card(
        elevation: 2,
        child: Container(
          height: 200,
          child: Center(
            child: Text(
              'Collecting parking data...',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      );
    }

    // Convert data to chart points
    List<FlSpot> spots = [];
    double minTime = chartData.first.time.millisecondsSinceEpoch.toDouble();
    
    for (int i = 0; i < chartData.length; i++) {
      ParkingDataPoint point = chartData[i];
      double x = (point.time.millisecondsSinceEpoch - minTime) / (1000 * 60); // Convert to minutes
      double y = point.carCount.toDouble();
      spots.add(FlSpot(x, y));
    }

    // Find max values for scaling
    double maxCars = chartData.map((p) => p.carCount).reduce((a, b) => a > b ? a : b).toDouble();
    double maxTime = spots.isNotEmpty ? spots.last.x : 10;
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.trending_up, color: Theme.of(context).colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Parking Occupancy Over Time',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Live',
                    style: TextStyle(
                      color: Colors.blue,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Container(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    horizontalInterval: maxCars > 5 ? 2 : 1,
                    verticalInterval: maxTime > 20 ? 5 : 2,
                    getDrawingHorizontalLine: (value) {
                      return FlLine(
                        color: Colors.grey.withOpacity(0.3),
                        strokeWidth: 1,
                      );
                    },
                    getDrawingVerticalLine: (value) {
                      return FlLine(
                        color: Colors.grey.withOpacity(0.3),
                        strokeWidth: 1,
                      );
                    },
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      axisNameWidget: Text(
                        'Time →',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: maxTime > 20 ? 5 : 2,
                        getTitlesWidget: (value, meta) {
                          if (chartData.length > value.toInt()) {
                            DateTime time = chartData[value.toInt()].time;
                            return Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                            );
                          }
                          return Text('');
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      axisNameWidget: Text(
                        'Cars',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: maxCars > 5 ? 2 : 1,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            '${value.toInt()}',
                            style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                  minX: 0,
                  maxX: maxTime > 5 ? maxTime : 5,
                  minY: 0,
                  maxY: maxCars > 3 ? maxCars + 1 : 4,
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) {
                          return FlDotCirclePainter(
                            radius: 4,
                            color: Colors.blue,
                            strokeWidth: 2,
                            strokeColor: Colors.white,
                          );
                        },
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withOpacity(0.1),
                      ),
                    ),
                  ],
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Updated every 30s',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveCarsSection(Map<String, CarSession> activeCars) {
    List<MapEntry<String, CarSession>> sortedEntries = activeCars.entries.toList();
    sortedEntries.sort((a, b) => b.value.entryTime.compareTo(a.value.entryTime));
    // Removed take(20) limit - show all active cars
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.directions_car, color: Theme.of(context).colorScheme.primary),
                SizedBox(width: 8),
                Text('Currently Parked Cars', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                Spacer(),
                Chip(
                  label: Text('${activeCars.length}'), 
                  backgroundColor: Colors.green.withOpacity(0.1)
                ),
              ],
            ),
            SizedBox(height: 12),
            Container(
              height: 200,
              child: sortedEntries.isNotEmpty
                  ? ListView.separated(
                      itemCount: sortedEntries.length,
                      separatorBuilder: (context, index) => Divider(height: 1),
                      itemBuilder: (context, index) {
                        String carId = sortedEntries[index].key;
                        CarSession session = sortedEntries[index].value;
                        Duration currentDuration = session.currentDuration;
                        
                        return ListTile(
                          dense: true,
                          leading: Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: session.enteredCorrectly ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.directions_car, color: session.enteredCorrectly ? Colors.green : Colors.red, size: 20),
                          ),
                          title: Text(carId, style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            'Entered: ${session.entryTime.toString().substring(11, 19)}\n'
                            'Duration: ${_formatDuration(currentDuration)}\n'
                            'Status: ${session.enteredCorrectly ? "Correct" : "Wrong"} parking'
                            // NEW: Show buffer status
                            + (session.wasBuffered ? ' • Had buffered events' : ''),
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: Container(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                            child: Text('ACTIVE', style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        );
                      },
                    )
                  : Center(child: Text('No cars currently parked', style: TextStyle(color: Colors.grey))),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildRecentEventsSection(List<ParkingEvent> events) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: Theme.of(context).colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Recent Events (from ESP32)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Spacer(),
                Chip(
                  label: Text('${events.length}'),
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                ),
              ],
            ),
            SizedBox(height: 12),
            Container(
              height: 180,
              child: events.isNotEmpty
                  ? ListView.separated(
                      itemCount: events.length, // Show all events
                      separatorBuilder: (context, index) => Divider(height: 1),
                      itemBuilder: (context, index) {
                        final event = events[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          leading: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: event.ledColor == "green" ? Colors.green : 
                                     event.ledColor == "red" ? Colors.red : Colors.blue,
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text(
                            event.description,
                            style: TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Row(
                            children: [
                              Text(
                                "${event.carId} • ${event.displayTimestamp.toString().substring(11, 19)}",  // NEW: Use displayTimestamp
                                style: TextStyle(fontSize: 10),
                              ),
                              // NEW: Buffer indicators
                              if (event.isBuffered) ...[
                                SizedBox(width: 4),
                                Icon(Icons.storage, size: 10, color: Colors.orange),
                              ],
                            ],
                          ),
                          trailing: Icon(
                            event.isCorrect ? Icons.check_circle : Icons.error,
                            color: event.isCorrect ? Colors.green : Colors.red,
                            size: 16,
                          ),
                        );
                      },
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.sensors_off, color: Colors.grey, size: 48),
                          SizedBox(height: 8),
                          Text(
                            'Waiting for ESP32 events...',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlSection(int eventCount) {
    return Column(
      children: [
        Card(
          elevation: 1,
          child: ListTile(
            leading: Icon(Icons.cloud_done, color: Colors.green),
            title: Text('Firebase RTDB Connected'),
            subtitle: Text('$eventCount events received from ESP32'),
            dense: true,
          ),
        ),
        SizedBox(height: 8),
        Card(
          elevation: 1,
          color: Colors.red[50],
          child: ListTile(
            leading: Icon(Icons.delete_forever, color: Colors.red),
            title: Text('Clear All Data', style: TextStyle(color: Colors.red[800])),
            subtitle: Text('Remove all events (for debugging)', style: TextStyle(color: Colors.red[600])),
            trailing: OutlinedButton(
              onPressed: () => _showClearConfirmDialog(),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              child: Text('Clear'),
            ),
            dense: true,
          ),
        ),
      ],
    );
  }

  void _resetWaitTimeTracking() {
    waitTimes = {1: [], 2: [], 3: [], 4: []};
    waitCounters = {1: 0, 2: 0, 3: 0, 4: 0};
    totalEventCount = 0;
    
    activeCars.clear();
    completedSessions.clear();
    
    // Reset chart data
    parkingChartData.clear();
    
    // NEW: Reset buffer stats
    bufferedEventsCount = 0;
    syncedEventsCount = 0;
    lastSyncTime = null;
    
    // Reset all ValueNotifiers
    currentEventNotifier.value = null;
    recentEventsNotifier.value = [];
    activeCarsNotifier.value = {};
    completedSessionsNotifier.value = [];
    eventStatsNotifier.value = {};
    carStatsNotifier.value = {};
    parkingChartDataNotifier.value = [];
  }
  
  void _showClearConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear All Events?'),
        content: Text('This will permanently delete all parking events from Firebase RTDB and reset all tracking data.\n\nNote: ESP32 will continue generating new events.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await ParkingFirebaseService.clearAllEvents();
                _resetWaitTimeTracking();
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('All data cleared successfully')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error clearing data: $e')),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Clear All'),
          ),
        ],
      ),
    );
  }

  Widget _buildChartsSection(Map<String, dynamic> stats) {
    return SizedBox(
      height: 220,
      child: Row(
        children: [
          Expanded(child: _buildPieChart(stats)),
          SizedBox(width: 12),
          Expanded(child: _buildWaitTimeChart(stats)),
        ],
      ),
    );
  }
  
  Widget _buildPieChart(Map<String, dynamic> stats) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.analytics, size: 16),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    "LED Distribution",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              "${stats['total']} Events",
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
            SizedBox(height: 8),
            Expanded(
              child: stats['total'] > 0
                  ? PieChart(
                      PieChartData(
                        sections: [
                          if (stats['green'] > 0)
                            PieChartSectionData(
                              value: stats['green'].toDouble(),
                              color: Colors.green,
                              title: "${stats['green']}",
                              titleStyle: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                              radius: 35,
                            ),
                          if (stats['red'] > 0)
                            PieChartSectionData(
                              value: stats['red'].toDouble(),
                              color: Colors.red,
                              title: "${stats['red']}",
                              titleStyle: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                              radius: 35,
                            ),
                          if (stats['blue'] > 0)
                            PieChartSectionData(
                              value: stats['blue'].toDouble(),
                              color: Colors.blue,
                              title: "${stats['blue']}",
                              titleStyle: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                              radius: 35,
                            ),
                        ],
                        centerSpaceRadius: 20,
                        sectionsSpace: 2,
                        startDegreeOffset: -90,
                      ),
                    )
                  : Center(child: Text('No data from ESP32', style: TextStyle(color: Colors.grey, fontSize: 10))),
            ),
            SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildLegend("G", Colors.green, stats['green']),
                _buildLegend("R", Colors.red, stats['red']),
                _buildLegend("B", Colors.blue, stats['blue']),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildLegend(String label, Color color, int count) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        Text(label, style: TextStyle(fontSize: 8)),
        Text("$count", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
  
  Widget _buildWaitTimeChart(Map<String, dynamic> stats) {
    Map<int, double> waitTimes = stats['waitTimes'] ?? {1: 0.0, 2: 0.0, 3: 0.0, 4: 0.0};
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.access_time, size: 16),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    "Avg Wait Time",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Text(
              "Events between occurrences",
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            ),
            SizedBox(height: 8),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: _buildWaitTimeItem("Correct Entry", waitTimes[1]!, Colors.green, "1")),
                  Expanded(child: _buildWaitTimeItem("Wrong Entry", waitTimes[2]!, Colors.red, "2")),
                  Expanded(child: _buildWaitTimeItem("Correct Exit", waitTimes[3]!, Colors.green, "3")),
                  Expanded(child: _buildWaitTimeItem("Wrong Exit", waitTimes[4]!, Colors.blue, "4")),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildWaitTimeItem(String label, double waitTime, Color color, String typeNum) {
    String displayTime = waitTime > 0 ? waitTime.floor().toString() : "-";
    
    return Container(
      margin: EdgeInsets.symmetric(vertical: 2),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Center(
              child: Text(
                typeNum,
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            displayTime,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildCarSummaryCards(Map<String, dynamic> carStats) {
    return Row(
      children: [
        Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.directions_car, size: 32, color: Colors.green),
                  SizedBox(height: 8),
                  Text(
                    '${carStats['activeCars']}',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                  Text(
                    'Cars in Parking',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.access_time, size: 32, color: Colors.blue),
                  SizedBox(height: 8),
                  Text(
                    '${carStats['avgSessionMinutes'].toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                  ),
                  Text(
                    'Avg Minutes',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(Icons.history, size: 32, color: Colors.orange),
                  SizedBox(height: 8),
                  Text(
                    '${carStats['completedSessions']}',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  ),
                  Text(
                    'Completed',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildSessionHistorySection(List<CarSession> recentSessions) {
    // Removed take(20) limit - show all sessions
    
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: Theme.of(context).colorScheme.primary),
                SizedBox(width: 8),
                Text(
                  'Recent Parking Sessions',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Spacer(),
                Chip(
                  label: Text('${recentSessions.length}'),
                  backgroundColor: Colors.orange.withOpacity(0.1),
                  side: BorderSide(color: Colors.orange.withOpacity(0.3)),
                ),
              ],
            ),
            SizedBox(height: 12),
            Container(
              height: 200,
              child: recentSessions.isNotEmpty
                  ? ListView.separated(
                      itemCount: recentSessions.length,
                      separatorBuilder: (context, index) => Divider(height: 1),
                      itemBuilder: (context, index) {
                        CarSession session = recentSessions[index];
                        Duration duration = session.sessionDuration!;
                        
                        return ListTile(
                          dense: true,
                          leading: Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: session.enteredCorrectly 
                                  ? Colors.green.withOpacity(0.1)
                                  : Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.check_circle, 
                              color: session.enteredCorrectly ? Colors.green : Colors.red, 
                              size: 20
                            ),
                          ),
                          title: Text(
                            session.carId,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'Entry: ${session.entryTime.toString().substring(11, 19)}\n'
                            'Exit: ${session.exitTime!.toString().substring(11, 19)}\n'
                            'Status: ${session.enteredCorrectly ? "Correct" : "Wrong"} parking'
                            // NEW: Show buffer status
                            + (session.wasBuffered ? '\nHad buffered events' : ''),
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _formatDuration(duration),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange,
                                ),
                              ),
                              Text(
                                'duration',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.inbox, color: Colors.grey, size: 48),
                          SizedBox(height: 8),
                          Text(
                            'No completed sessions yet',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
  
  String _formatDuration(Duration duration) {
    int hours = duration.inHours;
    int minutes = duration.inMinutes % 60;
    int seconds = duration.inSeconds % 60;
    
    if (hours > 24) {
      return '${minutes}m ${seconds}s';
    }
    
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}