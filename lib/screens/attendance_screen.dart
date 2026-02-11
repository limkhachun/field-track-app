import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:camera/camera.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart'; 

import '../widgets/face_camera_view.dart';
import 'correction_request_screen.dart';
import '../services/tracking_service.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  ImageProvider? _appBarImage;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty && mounted) {
        final data = q.docs.first.data();
        final faceUrl = data['faceIdPhoto']?.toString();

        if (faceUrl != null && faceUrl.isNotEmpty) {
          if (faceUrl.startsWith('http')) {
            setState(() {
              _appBarImage = NetworkImage(faceUrl);
            });
          } else {
            final file = File(faceUrl);
            if (file.existsSync()) {
              setState(() {
                _appBarImage = FileImage(file);
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error loading profile: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text("att.title".tr()),
          backgroundColor: const Color(0xFF15438c),
          foregroundColor: Colors.white,
          elevation: 0,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: Colors.grey.shade300,
                backgroundImage: _appBarImage,
                child: _appBarImage == null
                    ? const Icon(Icons.person, color: Colors.grey, size: 20)
                    : null,
              ),
            ),
          ],
        ),
        body: const TabBarView(
          physics: NeverScrollableScrollPhysics(),
          children: [
            AttendanceActionTab(),
            HistoryTab(),
            ScheduleTab(),
            SubmitTab(),
          ],
        ),
        bottomNavigationBar: Container(
          color: Colors.white,
          child: SafeArea(
            child: TabBar(
              labelColor: const Color(0xFF15438c),
              unselectedLabelColor: Colors.black,
              indicatorColor: const Color(0xFF15438c),
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                Tab(icon: const Icon(Icons.touch_app), text: "att.tab_clock_in".tr()),
                Tab(icon: const Icon(Icons.history), text: "att.tab_history".tr()),
                Tab(icon: const Icon(Icons.calendar_month), text: "att.tab_schedule".tr()),
                Tab(icon: const Icon(Icons.assignment_return), text: "att.tab_submit".tr()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
//  Tab 1: Action Tab
// ==========================================

class AttendanceActionTab extends StatefulWidget {
  const AttendanceActionTab({super.key});
  @override
  State<AttendanceActionTab> createState() => _AttendanceActionTabState();
}

class _AttendanceActionTabState extends State<AttendanceActionTab> {
  bool _isLoading = false;
  String _staffName = "Staff";
  String _employeeId = "";
  
  String _currentAddress = "att.locating".tr();
  Timer? _timer;
  
  String? _referenceFaceIdPath; 
  XFile? _capturedPhoto;
  String _selectedAction = "Clock In"; 

  final Completer<GoogleMapController> _mapController = Completer();
  CameraPosition? _initialPosition;
  Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _fetchUserDataAndFaceId(); 
    _initLocation();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchUserDataAndFaceId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty && mounted) {
        final data = q.docs.first.data();
        
        setState(() {
          _staffName = data['personal']['name'] ?? "Staff";
          if (data['personal'] != null && data['personal']['empCode'] != null) {
            _employeeId = "(${data['personal']['empCode']})";
          }
        });

        final faceUrl = data['faceIdPhoto']?.toString();
        if (faceUrl != null) {
          if (faceUrl.startsWith('http')) {
             _downloadFaceImage(faceUrl);
          } else {
             setState(() => _referenceFaceIdPath = faceUrl);
          }
        }
      }
    } catch (e) {
      debugPrint("$e");
    }
  }

  Future<void> _downloadFaceImage(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/face_id_ref.jpg');
        await tempFile.writeAsBytes(response.bodyBytes);
        if (mounted) {
          setState(() => _referenceFaceIdPath = tempFile.path);
        }
      }
    } catch (e) {
      debugPrint("Download error: $e");
    }
  }

  Future<void> _initLocation() async {
    try {
      Position? pos = await _determinePosition();
      if (pos != null) {
        final latLng = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _initialPosition = CameraPosition(target: latLng, zoom: 15);
          _markers = {
            Marker(markerId: const MarkerId('current'), position: latLng)
          };
        });
        if (mounted) await _getAddressFromLatLng(pos);
      }
    } catch (e) {
      if (mounted) setState(() => _currentAddress = "att.location_error".tr());
    }
  }

  Future<void> _getAddressFromLatLng(Position position) async {
    try {
      List<Placemark> placemarks =
          await placemarkFromCoordinates(position.latitude, position.longitude);
      
      if (placemarks.isNotEmpty && mounted) {
        Placemark place = placemarks[0];
        
        // 详细地址拼接
        List<String> parts = [
          place.name ?? "",
          place.subThoroughfare ?? "", // 门牌号
          place.thoroughfare ?? "",    // 街道
          place.subLocality ?? "",     // 区域/Taman
          place.locality ?? "",        // 城市
          place.postalCode ?? "",
          place.administrativeArea ?? "", // 州
          place.country ?? ""
        ];

        String detailedAddress = parts
            .where((p) => p.isNotEmpty)
            .toSet() 
            .join(", ");

        setState(() => _currentAddress = detailedAddress);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _currentAddress =
            "GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}");
      }
    }
  }

  Future<Position?> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high));
  }

  // 🟢 核心修改 1: 简化后的校验逻辑
  Future<bool> _validateRestrictions() async {
    setState(() => _isLoading = true);
    
    try {
      final doc = await FirebaseFirestore.instance.collection('settings').doc('office_location').get();
      // 如果还没配置，暂时放行
      if (!doc.exists) return true;
      
      final data = doc.data() as Map<String, dynamic>;
      final double officeLat = (data['latitude'] as num).toDouble();
      final double officeLng = (data['longitude'] as num).toDouble();
      final double allowedRadius = (data['radius'] as num?)?.toDouble() ?? 500.0;

      // WiFi Check
      List<Map<String, String>> allowedWifiList = [];
      if (data['allowedWifis'] is List) {
        for (var item in data['allowedWifis']) {
          if (item is String) {
            allowedWifiList.add({'ssid': item, 'bssid': ''});
          } else if (item is Map) {
            allowedWifiList.add({
              'ssid': item['ssid']?.toString() ?? '',
              'bssid': item['bssid']?.toString().toLowerCase() ?? ''
            });
          }
        }
      } else if (data['wifiSSID'] is String) {
        allowedWifiList.add({'ssid': data['wifiSSID'], 'bssid': ''});
      }

      if (allowedWifiList.isNotEmpty) {
        final info = NetworkInfo();
        String? currentSSID = await info.getWifiName();
        String? currentBSSID = await info.getWifiBSSID(); 

        if (currentSSID != null) currentSSID = currentSSID.replaceAll('"', '');
        if (currentBSSID != null) currentBSSID = currentBSSID.toLowerCase();
        if (currentBSSID == "02:00:00:00:00:00") currentBSSID = null;

        bool isWifiValid = false;
        for (var config in allowedWifiList) {
          bool ssidMatch = config['ssid'] == currentSSID;
          bool bssidMatch = true;
          if (config['bssid'] != null && config['bssid']!.isNotEmpty) {
             if (currentBSSID == null) {
               throw "Unable to verify WiFi security.\nPlease enable GPS/Location permission.";
             }
             bssidMatch = config['bssid'] == currentBSSID;
          }
          if (ssidMatch && bssidMatch) {
            isWifiValid = true;
            break;
          }
        }

        if (!isWifiValid) {
           // 🟢 简洁提示：未连接公司 WiFi
           throw "Not connected to company WiFi.\nPlease connect to clock in.";
        }
      }

      // GPS Check
      Position? currentPos = await _determinePosition();
      if (currentPos == null) throw "Cannot determine GPS location.";

      double distanceInMeters = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        officeLat,
        officeLng,
      );

      if (distanceInMeters > allowedRadius) {
        // 🟢 简洁提示：位置不对
        throw "You are outside office range.\nPlease move closer to clock in.";
      }

      return true;

    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Access Denied"), 
            content: Text(e.toString()),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showActionPicker() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    
    final q = await FirebaseFirestore.instance
        .collection('attendance')
        .where('uid', isEqualTo: user.uid)
        .where('date', isEqualTo: todayStr)
        .get();

    bool hasAnyRecord = q.docs.isNotEmpty; 
    
    bool isLastVerified = false;
    String? lastSession;
    bool hasClockedOut = false; // 标记是否已打卡下班

    if (hasAnyRecord) {
      final docs = q.docs;
      docs.sort((a, b) => (a['timestamp'] as Timestamp).compareTo(b['timestamp'] as Timestamp));
      final last = docs.last;
      
      lastSession = last['session'];
      isLastVerified = last['verificationStatus'] == 'Verified';
      
      // 检查是否有 Clock Out 记录
      hasClockedOut = docs.any((doc) => doc['session'] == 'Clock Out' && doc['verificationStatus'] == 'Verified');
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, 
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("att.select_action".tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              
              _buildActionTile(
                title: "att.act_clock_in".tr(),
                subtitle: hasAnyRecord 
                    ? "att.sub_locked_submitted".tr() 
                    : "att.sub_start_shift".tr(),
                icon: Icons.login,
                color: Colors.green,
                isLocked: hasAnyRecord, 
                onTap: () => _handleAction("Clock In"),
              ),
              
              const Divider(),

              // 🟢 核心修改 2: 如果已 Clock Out，禁用 Break 按钮
              _buildActionTile(
                title: "att.act_break_out".tr(),
                subtitle: hasClockedOut 
                    ? "Shift Ended" 
                    : ((lastSession == 'Break Out' && isLastVerified) ? "att.sub_locked_verified".tr() : "att.sub_lunch".tr()),
                icon: Icons.coffee,
                color: Colors.orange,
                isLocked: !hasAnyRecord || (lastSession == 'Break Out' && isLastVerified) || hasClockedOut,
                onTap: () => _handleAction("Break Out"),
              ),

              _buildActionTile(
                title: "att.act_break_in".tr(),
                subtitle: hasClockedOut 
                    ? "Shift Ended" 
                    : ((lastSession == 'Break In' && isLastVerified) ? "att.sub_locked_verified".tr() : "att.sub_back_work".tr()),
                icon: Icons.work_history,
                color: Colors.blue,
                isLocked: !hasAnyRecord || (lastSession == 'Break In' && isLastVerified) || hasClockedOut,
                onTap: () => _handleAction("Break In"),
              ),

              const Divider(),

              _buildActionTile(
                title: "att.act_clock_out".tr(),
                subtitle: (lastSession == 'Clock Out' && isLastVerified) ? "att.sub_locked_verified".tr() : "att.sub_end_shift".tr(),
                icon: Icons.logout,
                color: Colors.red,
                isLocked: !hasAnyRecord || (lastSession == 'Clock Out' && isLastVerified),
                onTap: () => _handleAction("Clock Out"),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionTile({
    required String title, 
    required String subtitle, 
    required IconData icon, 
    required Color color, 
    required bool isLocked,
    required VoidCallback onTap
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isLocked ? Colors.grey : color, 
        child: Icon(isLocked ? Icons.lock : icon, color: Colors.white)
      ),
      title: Text(
        title, 
        style: TextStyle(
          color: isLocked ? Colors.grey : Colors.black,
          decoration: isLocked ? TextDecoration.lineThrough : null
        )
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      onTap: isLocked ? null : onTap,
      enabled: !isLocked,
    );
  }

  void _handleAction(String action) async {
    Navigator.pop(context); 

    bool isAllowed = await _validateRestrictions();
    if (!isAllowed) return; 

    setState(() => _selectedAction = action);
    _takePhoto(); 
  }

  Future<void> _takePhoto() async {
    if (_referenceFaceIdPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("att.err_no_face_id".tr())));
      return;
    }

    final result = await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) =>
                FaceCameraView(referencePath: _referenceFaceIdPath))); 

    if (result != null && result is XFile && mounted) {
      setState(() {
        _capturedPhoto = result;
      });
      String actionDisplay = _getActionDisplayText(_selectedAction);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("att.msg_photo_captured".tr(args: [actionDisplay])),
          backgroundColor: Colors.green));
    }
  }

  String _getActionDisplayText(String action) {
    if(action == "Clock In") return "att.act_clock_in".tr();
    if(action == "Break Out") return "att.act_break_out".tr();
    if(action == "Break In") return "att.act_break_in".tr();
    if(action == "Clock Out") return "att.act_clock_out".tr();
    return action;
  }

  Future<void> _submitAttendance() async {
    if (_capturedPhoto == null) return;

    setState(() => _isLoading = true);
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      Position? position = await _determinePosition();
      if (position == null) throw "GPS Signal Lost. Cannot submit.";
      await _getAddressFromLatLng(position);

      String fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      Reference ref = FirebaseStorage.instance
          .ref()
          .child('attendance_photos')
          .child(user.uid)
          .child(fileName);
      await ref.putFile(File(_capturedPhoto!.path));
      String photoUrl = await ref.getDownloadURL();

      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);
      final timeStr = DateFormat('HH:mm:ss').format(now);
      
      final CollectionReference attCollection = FirebaseFirestore.instance.collection('attendance');

      Map<String, dynamic> newRecord = {
        'uid': user.uid,
        'name': _staffName,
        'email': user.email,
        'date': todayStr,
        'verificationStatus': "Pending", 
        'session': _selectedAction, 
        'location': GeoPoint(position.latitude, position.longitude),
        'address': _currentAddress,
        'photoUrl': photoUrl, 
        'timestamp': FieldValue.serverTimestamp(),
        'manualIn': null,
        'manualOut': null,
      };

      if (_selectedAction == 'Clock In') {
        newRecord['timeIn'] = FieldValue.serverTimestamp();
        newRecord['timeInStr'] = timeStr;
      } else if (_selectedAction == 'Break Out') {
        newRecord['breakOut'] = FieldValue.serverTimestamp();
      } else if (_selectedAction == 'Break In') {
        newRecord['breakIn'] = FieldValue.serverTimestamp();
      } else if (_selectedAction == 'Clock Out') {
        newRecord['timeOut'] = FieldValue.serverTimestamp();
        newRecord['timeOutStr'] = timeStr;
      }

      await attCollection.add(newRecord);

      final uid = user.uid;
      if (_selectedAction == 'Clock In') {
        await TrackingService().startTracking(uid);
      } 
      else if (_selectedAction == 'Break Out') {
        await TrackingService().stopTracking();
      }
      else if (_selectedAction == 'Break In') {
        await TrackingService().startTracking(uid);
      }
      else if (_selectedAction == 'Clock Out') {
        await TrackingService().stopTracking();
      }

      if (mounted) {
        String actionDisplay = _getActionDisplayText(_selectedAction);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("att.msg_submitted".tr(args: [actionDisplay])),
            backgroundColor: Colors.green));
        setState(() {
          _capturedPhoto = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final now = DateTime.now();
    final displayDate = DateFormat('dd/MM/yyyy (EEE)').format(now);
    const whiteTextColor = Color(0xFFFFFFFF);
    const naviColor = Color(0xFF15438c);

    String actionDisplay = _getActionDisplayText(_selectedAction);

    return SingleChildScrollView(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomCenter,
            children: [
              SizedBox(
                height: 180,
                width: double.infinity,
                child: _initialPosition == null
                    ? Container(color: Colors.grey[300], child: const Center(child: CircularProgressIndicator()))
                    : GoogleMap(
                        mapType: MapType.normal,
                        initialCameraPosition: _initialPosition!,
                        markers: _markers,
                        myLocationEnabled: true,
                        zoomControlsEnabled: false,
                        onMapCreated: (GoogleMapController controller) {
                          if (!_mapController.isCompleted) {
                            _mapController.complete(controller);
                          }
                        },
                      ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _currentAddress,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(
              color: naviColor,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.white, size: 20),
                      const SizedBox(height: 4),
                      Text(displayDate, style: const TextStyle(fontWeight: FontWeight.bold, color: whiteTextColor)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                Text(_staffName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: whiteTextColor)),
                Text(_employeeId, style: const TextStyle(fontSize: 16, color: Colors.white)),

                const SizedBox(height: 20),
                const Divider(color: Colors.white),
                const SizedBox(height: 40),

                GestureDetector(
                  onTap: _showActionPicker,
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.amber,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(color: Colors.amber.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 5))
                      ],
                      image: _capturedPhoto != null
                          ? DecorationImage(image: FileImage(File(_capturedPhoto!.path)), fit: BoxFit.cover)
                          : null,
                    ),
                    child: _capturedPhoto == null
                        ? const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 40)
                        : null,
                  ),
                ),

                const SizedBox(height: 20),
                
                if (_capturedPhoto == null)
                  Text("att.hint_tap_camera".tr(), style: const TextStyle(color: Colors.white70, fontSize: 12)),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      backgroundColor: _capturedPhoto != null ? whiteTextColor : Colors.grey.shade300,
                      foregroundColor: _capturedPhoto != null ? naviColor : Colors.grey.shade500,
                      elevation: _capturedPhoto != null ? 3 : 0,
                    ),
                    onPressed: () {
                      if (_capturedPhoto == null) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Row(
                              children: [
                                const Icon(Icons.camera_alt_outlined, color: Colors.orange),
                                const SizedBox(width: 10),
                                Text("att.dialog_photo_title".tr()),
                              ],
                            ),
                            content: Text("att.dialog_photo_content".tr()),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text("att.btn_ok".tr(), style: const TextStyle(color: Colors.blue)),
                              ),
                            ],
                          ),
                        );
                      } else {
                        _submitAttendance();
                      }
                    },
                    child: Text(
                      _capturedPhoto != null 
                        ? "att.btn_confirm".tr(args: [actionDisplay])
                        : "att.btn_clock_attendance".tr(),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
//  Tab 2: History (No Changes)
// ==========================================
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  bool _isDescending = true;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Center(child: Text("Please login"));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    Text("att.header_date".tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () {
                        setState(() {
                          _isDescending = !_isDescending;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(
                          _isDescending ? Icons.arrow_downward : Icons.arrow_upward,
                          size: 16,
                          color: const Color(0xFF15438c),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                  flex: 4,
                  child: Text("att.header_address".tr(), style: const TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  flex: 2,
                  child: Text("att.header_status".tr(), style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.right)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('attendance')
                .where('uid', isEqualTo: user.uid)
                .orderBy('timestamp', descending: _isDescending)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Center(child: Text("att.no_history".tr(), style: const TextStyle(color: Colors.grey)));
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (ctx, i) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final ts = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
                  bool isVerified = data['verificationStatus'] == 'Verified';
                  
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(DateFormat('dd-MM-yyyy').format(ts),
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black54)),
                              Text(DateFormat('HH:mm:ss').format(ts), 
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: isVerified ? Colors.black87 : Colors.orange)), 
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            data['address'] ?? "Unknown",
                            style: const TextStyle(fontSize: 12, color: Color(0xFF15438c)),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: isVerified 
                              ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
                              : const Icon(Icons.access_time, color: Colors.orange, size: 18)
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ==========================================
//  Tab 3: Schedule (No Changes)
// ==========================================

class ScheduleTab extends StatefulWidget {
  const ScheduleTab({super.key});
  @override
  State<ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<ScheduleTab> {
  DateTime _currentStartDate = DateTime.now();
  String? _myEmpCode;
  bool _isFetchingUser = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
    _fetchEmployeeCode();
  }

  Future<void> _fetchEmployeeCode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
      if (q.docs.isNotEmpty && mounted) {
        setState(() { _myEmpCode = q.docs.first.id; _isFetchingUser = false; });
      } else { if(mounted) setState(() => _isFetchingUser = false); }
    } catch (e) { if(mounted) setState(() => _isFetchingUser = false); }
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  String _formatDuration(Duration d) {
    if (d.inMinutes == 0) return "0.00";
    String hours = d.inHours.toString();
    String mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    return "$hours.$mins";
  }

  @override
  Widget build(BuildContext context) {
    if (_isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (_myEmpCode == null) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final endDate = _currentStartDate.add(const Duration(days: 6));
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(endDate);
    final displayRange = "${DateFormat('dd MMM').format(_currentStartDate)} - ${DateFormat('dd MMM').format(endDate)}";

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: _myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr)
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;

                  DateTime? schedStart = scheduleData['start'] != null ? (scheduleData['start'] as Timestamp).toDate() : null;
                  DateTime? schedEnd = scheduleData['end'] != null ? (scheduleData['end'] as Timestamp).toDate() : null;

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      String status = "Absent";
                      Color statusColor = Colors.grey;
                      String lateStr = "0.00";
                      String underStr = "0.00";
                      String otStr = "0.00";

                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        final docs = attSnapshot.data!.docs;
                        final verifiedDocs = docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified';
                        }).toList();

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (e) { clockInDoc = null; }

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (e) { clockOutDoc = null; }

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (e) { breakOutDoc = null; }

                        if (clockInDoc != null) {
                           final ts = ((clockInDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeIn = DateFormat('HH:mm').format(ts);
                           status = "Working";
                           statusColor = Colors.blue;
                           if (schedStart != null && ts.isAfter(schedStart)) {
                             lateStr = _formatDuration(ts.difference(schedStart));
                           }
                        }

                        if (clockOutDoc != null) {
                           final ts = ((clockOutDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                           status = "Present";
                           statusColor = Colors.green;
                          if (schedEnd != null) {
                           if (ts.isAfter(schedEnd)) {
                             otStr = _formatDuration(ts.difference(schedEnd));
                           } else {
                             underStr = _formatDuration(schedEnd.difference(ts));
                           }
                         }
                        } else if (breakOutDoc != null) {
                           final ts = ((breakOutDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        }
                      }

                      return _buildScheduleCard(
                        scheduleData, timeIn, timeOut, status, statusColor, lateStr, underStr, otStr
                      );
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildScheduleCard(Map<String, dynamic> scheduleData, String inTime, String outTime, String status, Color color, String late, String under, String ot) {
    final dateObj = DateTime.parse(scheduleData['date']);
    final weekDay = DateFormat('EEEE').format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy').format(dateObj);
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    Color lateColor = late == "0.00" ? Colors.black : Colors.red;
    Color underColor = under == "0.00" ? Colors.black : Colors.red;

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)),
                Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (status != "Absent") ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                          child: Text(status, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      _buildStatRow("att.label_late".tr(), late, lateColor),
                      const SizedBox(height: 4),
                      _buildStatRow("att.label_under".tr(), under, underColor),
                      const SizedBox(height: 4),
                      _buildStatRow("att.label_ot".tr(), ot, Colors.black),
                    ],
                  ),
                )
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(
            child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15)),
          ),
        )
      ],
    );
  }

  Widget _buildStatRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$label: ", style: const TextStyle(fontSize: 11, color: Colors.black)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}

// ==========================================
//  Tab 4: Submit (Modified: Limit Date to Today)
// ==========================================

class SubmitTab extends StatefulWidget {
  const SubmitTab({super.key});
  @override
  State<SubmitTab> createState() => _SubmitTabState();
}

class _SubmitTabState extends State<SubmitTab> {
  DateTime _currentStartDate = DateTime.now();
  String? _myEmpCode;
  bool _isFetchingUser = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _currentStartDate = now.subtract(Duration(days: now.weekday - 1));
    _fetchEmployeeCode();
  }

  Future<void> _fetchEmployeeCode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final q = await FirebaseFirestore.instance.collection('users').where('authUid', isEqualTo: user.uid).limit(1).get();
      if (q.docs.isNotEmpty && mounted) {
        setState(() { _myEmpCode = q.docs.first.id; _isFetchingUser = false; });
      } else { if(mounted) setState(() => _isFetchingUser = false); }
    } catch (e) { if(mounted) setState(() => _isFetchingUser = false); }
  }

  void _changeWeek(int weeks) {
    setState(() => _currentStartDate = _currentStartDate.add(Duration(days: 7 * weeks)));
  }

  @override
  Widget build(BuildContext context) {
    if (_isFetchingUser) return const Center(child: CircularProgressIndicator());
    if (_myEmpCode == null) return Center(child: Text("att.err_profile_not_linked".tr()));

    final user = FirebaseAuth.instance.currentUser;
    final now = DateTime.now();
    
    // 🟢 MODIFICATION 3: Limit End Date to Today
    final originalEndDate = _currentStartDate.add(const Duration(days: 6));
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    
    // Use the earlier of the two dates (end of week OR today)
    DateTime effectiveEndDate = originalEndDate.isAfter(endOfToday) ? endOfToday : originalEndDate;
    
    final startStr = DateFormat('yyyy-MM-dd').format(_currentStartDate);
    final endStr = DateFormat('yyyy-MM-dd').format(effectiveEndDate);
    
    // Header keeps showing the full week for navigation clarity
    final displayRange = "${DateFormat('dd MMM').format(_currentStartDate)} - ${DateFormat('dd MMM').format(originalEndDate)}";
    
    // If user scrolled to future week, don't show list
    bool isFutureWeek = _currentStartDate.isAfter(endOfToday);

    return Column(
      children: [
        // Header (Same as ScheduleTab)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.grey), onPressed: () => _changeWeek(-1)),
              Text(displayRange, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF15438c))),
              IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.grey), onPressed: () => _changeWeek(1)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text("att.hint_correction".tr(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        
        Expanded(
          child: isFutureWeek 
            ? Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey))) 
            : StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('schedules')
                .where('userId', isEqualTo: _myEmpCode)
                .where('date', isGreaterThanOrEqualTo: startStr)
                .where('date', isLessThanOrEqualTo: endStr) // 🟢 Restricted Date
                .orderBy('date')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              final scheduleDocs = snapshot.data?.docs ?? [];
              if (scheduleDocs.isEmpty) return Center(child: Text("att.no_shifts".tr(), style: const TextStyle(color: Colors.grey)));
              
              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: scheduleDocs.length,
                itemBuilder: (context, index) {
                  final scheduleData = scheduleDocs[index].data() as Map<String, dynamic>;
                  final dateStr = scheduleData['date'] as String;
                  
                  String? attendanceId; 

                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('attendance')
                        .where('uid', isEqualTo: user?.uid)
                        .where('date', isEqualTo: dateStr)
                        .snapshots(),
                    builder: (context, attSnapshot) {
                      String timeIn = "--:--";
                      String timeOut = "--:--";
                      
                      if (attSnapshot.hasData && attSnapshot.data!.docs.isNotEmpty) {
                        final docs = attSnapshot.data!.docs;
                        attendanceId = docs.first.id;
                        
                        final verifiedDocs = docs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return data['verificationStatus'] == 'Verified';
                        }).toList();

                        QueryDocumentSnapshot? clockInDoc;
                        try { clockInDoc = verifiedDocs.firstWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock In'); } catch (e) { clockInDoc = null; }

                        QueryDocumentSnapshot? clockOutDoc;
                        try { clockOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Clock Out'); } catch (e) { clockOutDoc = null; }

                        QueryDocumentSnapshot? breakOutDoc;
                        try { breakOutDoc = verifiedDocs.lastWhere((d) => (d.data() as Map<String,dynamic>)['session'] == 'Break Out'); } catch (e) { breakOutDoc = null; }

                        if (clockInDoc != null) {
                           final ts = ((clockInDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeIn = DateFormat('HH:mm').format(ts);
                        }

                        if (clockOutDoc != null) {
                           final ts = ((clockOutDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        } else if (breakOutDoc != null) {
                           final ts = ((breakOutDoc.data() as Map<String,dynamic>)['timestamp'] as Timestamp).toDate();
                           timeOut = DateFormat('HH:mm').format(ts);
                        }
                      }

                      return _buildSubmitCard(
                        scheduleData, attendanceId, timeIn, timeOut
                      );
                    }
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitCard(Map<String, dynamic> scheduleData, String? attendanceId, String inTime, String outTime) {
    final dateObj = DateTime.parse(scheduleData['date']);
    final weekDay = DateFormat('EEEE').format(dateObj);
    final fmtDate = DateFormat('dd/MM/yyyy').format(dateObj);
    String shiftStart = scheduleData['start'] != null ? DateFormat('HH:mm').format((scheduleData['start'] as Timestamp).toDate().toLocal()) : "--:--";
    String shiftEnd = scheduleData['end'] != null ? DateFormat('HH:mm').format((scheduleData['end'] as Timestamp).toDate().toLocal()) : "--:--";

    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => CorrectionRequestScreen(
          date: dateObj, 
          attendanceId: attendanceId, 
          originalIn: inTime, 
          originalOut: outTime
        )));
      },
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.blue.withValues(alpha:0.3))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("${'att.label_shift'.tr()} ($shiftStart - $shiftEnd)", style: const TextStyle(color: Color(0xFF15438c), fontWeight: FontWeight.bold, fontSize: 15)), 
                  Text("$weekDay ($fmtDate)", style: const TextStyle(color: Colors.blueGrey, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 12),
              
              Row(
                children: [
                  Expanded(child: _buildTimeBox("att.label_in".tr(), inTime)),
                  const SizedBox(width: 10),
                  Expanded(child: _buildTimeBox("att.label_out".tr(), outTime)),
                  const SizedBox(width: 16),
                  const Icon(Icons.edit_note, color: Colors.blue, size: 28), 
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeBox(String label, String time) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(8)),
          child: Center(
            child: Text(time, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF15438c), fontSize: 15)),
          ),
        )
      ],
    );
  }
}