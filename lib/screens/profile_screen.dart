import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:easy_localization/easy_localization.dart'; // 引入国际化包

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 状态变量
  bool _isLoading = true;
  String? _docId;
  Map<String, dynamic> _rawData = {};
  
  // 实时监听订阅
  StreamSubscription<DocumentSnapshot>? _userSubscription;
  StreamSubscription<QuerySnapshot>? _requestSubscription;

  // 权限状态逻辑
  String _status = 'active';
  bool get _isEditable => _status == 'editable';
  bool _hasPendingRequest = false; 

  // 控制器
  final Map<String, TextEditingController> _controllers = {};
  final TextEditingController _requestController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initRealtimeListeners();
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _requestSubscription?.cancel();
    _requestController.dispose();
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  // 1. 初始化实时监听
  void _initRealtimeListeners() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final querySnapshot = await _db
          .collection('users')
          .where('authUid', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      _docId = querySnapshot.docs.first.id;

      // 监听用户信息变更 (用于 Admin 开启编辑权限后实时响应)
      _userSubscription = _db
          .collection('users')
          .doc(_docId)
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists && mounted) {
          setState(() {
            _rawData = snapshot.data() as Map<String, dynamic>;
            _status = _rawData['status'] ?? 'active';
            _isLoading = false;
            
            if (_isEditable) {
               _syncControllersWithData(); 
            }
          });
        }
      });

      // 监听是否存在待处理的编辑申请
      _requestSubscription = _db
          .collection('edit_requests')
          .where('userId', isEqualTo: _docId)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen((snapshot) {
        if (mounted) {
          setState(() {
            _hasPendingRequest = snapshot.docs.isNotEmpty;
          });
        }
      });

    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("profile.error_fetch".tr(args: [e.toString()]))));
      }
    }
  }

  String _val(List<String> keys) {
    dynamic current = _rawData;
    for (String key in keys) {
      if (current is Map && current[key] != null) {
        current = current[key];
      } else {
        return '-';
      }
    }
    return current.toString();
  }

  TextEditingController _getController(String key, String initialValue) {
    if (!_controllers.containsKey(key)) {
      String text = initialValue == '-' ? '' : initialValue;
      _controllers[key] = TextEditingController(text: text);
    }
    return _controllers[key]!;
  }
  
  void _syncControllersWithData() {
    // 逻辑已在 _buildField 中通过控制器自动处理
  }

  // 2. 保存个人资料 (Admin 批准后用户可操作)
  Future<void> _saveProfile() async {
    if (_docId == null) return;
    
    setState(() => _isLoading = true);
    try {
      Map<String, dynamic> updates = {};
      _controllers.forEach((key, controller) {
        updates[key] = controller.text.trim();
      });

      updates['meta.lastMobileUpdate'] = FieldValue.serverTimestamp();

      await _db.collection('users').doc(_docId).update(updates);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("profile.save_success".tr()), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("profile.save_failed".tr(args: [e.toString()]))));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 3. 提交编辑申请
  Future<void> _submitRequest(String reason) async {
      try {
        await _db.collection('edit_requests').add({
          'userId': _docId,
          'empName': _val(['personal', 'name']),
          'empCode': _val(['personal', 'empCode']),
          'request': reason,
          'status': 'pending',
          'date': FieldValue.serverTimestamp(),
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("profile.request_sent".tr())),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("profile.request_failed".tr())));
        }
      }
  }

  void _showEditRequestDialog() {
    showDialog(
      context: context,
      barrierDismissible: false, // Prevent accidental closing
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: Text(
          "profile.dialog_title".tr(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "profile.dialog_subtitle".tr(),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _requestController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: "profile.reason_hint".tr(),
                hintStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.blue, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        actionsAlignment: MainAxisAlignment.end, // Force alignment to the right
        actions: [
          // 1. Cancel Button (Grey / Neutral)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _requestController.clear();
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey[700],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: Text(
              "profile.btn_cancel".tr(),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          
          const SizedBox(width: 8), // Spacing between buttons

          // 2. Send Button (Blue / Highlighted)
          ElevatedButton.icon(
            onPressed: () async {
              if (_requestController.text.trim().isEmpty) return;
              String reason = _requestController.text.trim();
              Navigator.pop(context);
              _requestController.clear();
              await _submitRequest(reason);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue[700], // Distinct Color
              foregroundColor: Colors.white,
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            icon: const Icon(Icons.send, size: 16),
            label: Text("profile.btn_send".tr()),
          ),
        ],
      ),
    );
  }
  // --- 界面构建组件 ---

  Widget _buildField(String labelKey, List<String> path, {bool locked = false}) {
    String value = _val(path);
    String fieldKey = path.join('.');
    String translatedLabel = labelKey.tr();

    // 只读模式 (未授权编辑 或 字段被强制锁定)
    if (!_isEditable || locked) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translatedLabel,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: locked ? Colors.grey[200] : Colors.grey[50], 
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 15, 
                        color: locked ? Colors.grey[600] : Colors.black87
                      ),
                    ),
                  ),
                  if (locked && _isEditable)
                     const Icon(Icons.lock, size: 16, color: Colors.grey),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 编辑模式
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextFormField(
        controller: _getController(fieldKey, value),
        decoration: InputDecoration(
          labelText: translatedLabel,
          labelStyle: TextStyle(color: Colors.grey[600]),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
    );
  }

  Widget _buildGroupCard(String titleKey, List<Widget> children) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titleKey.tr().toUpperCase(),
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                    fontSize: 13,
                    letterSpacing: 0.5)),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }

  // --- 各标签页内容 ---

  Widget _buildPersonalTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_bio", [
            _buildField("profile.field_name", ['personal', 'name']),
            _buildField("profile.field_nationality", ['personal', 'nationality']),
            _buildField("profile.field_religion", ['personal', 'religion']),
            _buildField("profile.field_race", ['personal', 'race']),
            _buildField("profile.field_gender", ['personal', 'gender']),
            _buildField("profile.field_marital", ['personal', 'marital']),
            _buildField("profile.field_blood", ['personal', 'blood']),
          ]),
          _buildGroupCard("profile.group_docs", [
            _buildField("profile.field_ic", ['personal', 'icNo'], locked: true),
            _buildField("profile.field_passport", ['foreign', 'id'], locked: true),
          ]),
          _buildGroupCard("profile.group_tax", [
            _buildField("profile.field_tax_disable", ['statutory', 'tax', 'disable']),
            _buildField("profile.field_tax_spouse", ['statutory', 'tax', 'spouseStatus']),
            _buildField("profile.field_tax_spouse_disable", ['statutory', 'tax', 'spouseDisable']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildAddressTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_local_addr", [
            _buildField("profile.field_addr_door", ['address', 'local', 'door']),
            _buildField("profile.field_addr_loc", ['address', 'local', 'loc']),
            _buildField("profile.field_addr_street", ['address', 'local', 'street']),
            _buildField("profile.field_addr_city", ['address', 'local', 'city']),
            _buildField("profile.field_addr_pin", ['address', 'local', 'pin']),
            _buildField("profile.field_addr_state", ['address', 'local', 'state']),
            _buildField("profile.field_addr_country", ['address', 'local', 'country']),
          ]),
          _buildGroupCard("profile.group_foreign_addr", [
            _buildField("profile.field_addr_door", ['address', 'foreign', 'door']),
            _buildField("profile.field_addr_loc", ['address', 'foreign', 'loc']),
            _buildField("profile.field_addr_street", ['address', 'foreign', 'street']),
            _buildField("profile.field_addr_city", ['address', 'foreign', 'city']),
            _buildField("profile.field_addr_pin", ['address', 'foreign', 'pin']),
            _buildField("profile.field_addr_state", ['address', 'foreign', 'state']),
            _buildField("profile.field_addr_country", ['address', 'foreign', 'country']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildContactTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // ⚠️ 安全锁定提示
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              border: Border.all(color: Colors.amber.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, color: Colors.amber[800], size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "profile.contact_security_notice".tr(),
                    style: TextStyle(fontSize: 13, color: Colors.brown[800], height: 1.4),
                  ),
                ),
              ],
            ),
          ),

          _buildGroupCard("profile.group_contact", [
            _buildField("profile.field_mobile", ['personal', 'mobile'], locked: true),
            _buildField("profile.field_email", ['personal', 'email'], locked: true),
          ]),
          
          _buildGroupCard("profile.group_emergency", [
            _buildField("profile.field_emergency_name", ['address', 'emergency', 'name']),
            _buildField("profile.field_emergency_rel", ['address', 'emergency', 'rel']),
            _buildField("profile.field_emergency_phone", ['address', 'emergency', 'no']),
          ]),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildFamilyTab() {
    List<dynamic> children = [];
    if (_rawData['family'] != null && _rawData['family']['children'] != null) {
      children = _rawData['family']['children'];
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildGroupCard("profile.group_spouse", [
            _buildField("profile.field_spouse_name", ['family', 'spouse', 'name']),
            _buildField("profile.field_dob", ['family', 'spouse', 'dob']),
            _buildField("profile.field_job", ['family', 'spouse', 'job']),
            _buildField("profile.field_spouse_id", ['family', 'spouse', 'id']),
            _buildField("profile.field_phone", ['family', 'spouse', 'phone']),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text("${'profile.group_children'.tr()} (${children.length})",
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          if (children.isEmpty)
            Center(
                child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text("profile.no_children".tr(),
                  style: const TextStyle(color: Colors.grey)),
            )),
          ...children.map((child) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  title: Text(child['name'] ?? 'Unknown',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text("${'profile.field_dob'.tr()}: ${child['dob'] ?? '-'}"),
                      Text("${'profile.field_gender'.tr()}: ${child['gender'] ?? '-'}"),
                      Text("${'profile.field_child_ic'.tr()}: ${child['cert'] ?? '-'}"),
                    ],
                  ),
                ),
              )),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  // --- 悬浮按钮构建 ---
  Widget? _buildFab() {
    if (_isEditable) {
      return FloatingActionButton.extended(
        onPressed: _isLoading ? null : _saveProfile,
        icon: const Icon(Icons.save),
        label: Text("profile.btn_save_changes".tr()),
        backgroundColor: Colors.green,
      );
    } 
    
    if (_hasPendingRequest) {
      return FloatingActionButton.extended(
        onPressed: null, 
        icon: const Icon(Icons.hourglass_top), 
        label: Text("profile.status_pending".tr()), 
        backgroundColor: Colors.grey,
      );
    }

    return FloatingActionButton.extended(
      onPressed: _showEditRequestDialog,
      icon: const Icon(Icons.edit_note),
      label: Text("profile.btn_request_update".tr()),
      backgroundColor: Colors.blue[800],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: Text("profile.title".tr()),
          elevation: 0,
          backgroundColor: Colors.blue[700],
          foregroundColor: Colors.white,
          bottom: TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            tabs: [
              Tab(text: "profile.tab_personal".tr()),
              Tab(text: "profile.tab_address".tr()),
              Tab(text: "profile.tab_contact".tr()),
              Tab(text: "profile.tab_family".tr()),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildPersonalTab(),
            _buildAddressTab(),
            _buildContactTab(),
            _buildFamilyTab(),
          ],
        ),
        floatingActionButton: _buildFab(),
      ),
    );
  }
}