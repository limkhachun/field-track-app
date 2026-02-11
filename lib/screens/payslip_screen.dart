import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:open_filex/open_filex.dart';
import 'package:easy_localization/easy_localization.dart';

class PayslipScreen extends StatefulWidget {
  const PayslipScreen({super.key});

  @override
  State<PayslipScreen> createState() => _PayslipScreenState();
}

class _PayslipScreenState extends State<PayslipScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isGenerating = false;

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Text("home.payslip".tr()), 
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black,
      ),
      body: Stack(
        children: [
          if (user == null) 
            const Center(child: Text("Please login first")),

          if (user != null)
            // 🟢 第一步：先通过 authUid 找到用户的 Profile ID (Document ID)
            FutureBuilder<QuerySnapshot>(
              future: FirebaseFirestore.instance
                  .collection('users')
                  .where('authUid', isEqualTo: user.uid)
                  .limit(1)
                  .get(),
              builder: (context, userSnap) {
                if (userSnap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                if (userSnap.hasError) {
                   return Center(child: Text("Error: ${userSnap.error}"));
                }

                if (!userSnap.hasData || userSnap.data!.docs.isEmpty) {
                  return const Center(child: Text("Profile not linked. Contact Admin."));
                }

                // 获取 Admin 端使用的真实文档 ID
                final String profileId = userSnap.data!.docs.first.id;

                // 🟢 第二步：用 Profile ID 查询薪资单
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('payslips')
                      .where('uid', isEqualTo: profileId) // 使用正确的 ID 查询
                      .where('status', isEqualTo: 'Published')
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.description_outlined, size: 80, color: Colors.grey[300]),
                            const SizedBox(height: 10),
                            const Text("No payslips found", style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      );
                    }

                    // 排序：月份倒序 (最新的在上面)
                    final docs = snapshot.data!.docs;
                    docs.sort((a, b) {
                      final monthA = (a.data() as Map<String, dynamic>)['month'] ?? '';
                      final monthB = (b.data() as Map<String, dynamic>)['month'] ?? '';
                      return monthB.compareTo(monthA);
                    });

                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final data = docs[index].data() as Map<String, dynamic>;
                        return _buildPayslipCard(data);
                      },
                    );
                  },
                );
              },
            ),
          
          // Loading Overlay
          if (_isGenerating)
            Container(
              color: Colors.black45,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text("Generating PDF...", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                  ],
                ),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildPayslipCard(Map<String, dynamic> data) {
    // 格式化月份 "2026-02" -> "February 2026"
    final dateObj = DateTime.tryParse("${data['month']}-01");
    final monthStr = dateObj != null ? DateFormat('MMMM yyyy').format(dateObj) : data['month'];
    final netPay = (data['net'] ?? 0).toDouble();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _generateAndOpenPdf(data), // 点击下载 PDF
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.picture_as_pdf, color: Colors.blue),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      monthStr,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Net Pay: RM ${netPay.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.download, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  // 📄 核心：生成 PDF 并打开
  Future<void> _generateAndOpenPdf(Map<String, dynamic> data) async {
    setState(() => _isGenerating = true);

    try {
      final pdf = pw.Document();

      // 提取数据
      final basic = (data['basic'] ?? 0).toDouble();
      final earnings = data['earnings'] as Map<String, dynamic>? ?? {};
      final deductions = data['deductions'] as Map<String, dynamic>? ?? {};
      
      final gross = (data['gross'] ?? 0).toDouble();
      final net = (data['net'] ?? 0).toDouble();
      final totalDed = (deductions['total'] ?? 0).toDouble();

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // 1. Header
                pw.Header(
                  level: 0,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text("RH RIDER HUB MOTOR (M) SDN. BHD.", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18)),
                      pw.SizedBox(height: 4),
                      pw.Text("NO.26&28, JALAN MERU IMPIAN B3, CASA KAYANGAN @ PUSAT PERNIAGAAN MERU IMPIAN,\nBANDAR MERU RAYA, 30020 IPOH, Perak", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                      pw.SizedBox(height: 10),
                      pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: pw.Text("Payment Date: ${data['paymentDate'] ?? '-'}", style: const pw.TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 20),

                // 2. Info Grid
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    // Left Col
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildPdfRow("Employee Name", data['staffName']),
                          _buildPdfRow("Department", data['department']),
                          _buildPdfRow("Employee Code", data['staffCode']),
                          _buildPdfRow("Pay Group", data['payGroup']),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    // Right Col
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildPdfRow("IC Number", data['icNo']),
                          _buildPdfRow("EPF Number", data['epfNo']),
                          _buildPdfRow("SOCSO Number", data['socsoNo']),
                          _buildPdfRow("Pay Period", data['period']),
                        ],
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 20),

                // 3. Finance Table (Headers)
                pw.Container(
                  decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(), bottom: pw.BorderSide())),
                  padding: const pw.EdgeInsets.symmetric(vertical: 5),
                  child: pw.Row(
                    children: [
                      pw.Expanded(flex: 3, child: pw.Text("EARNINGS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.Expanded(flex: 1, child: pw.Text("AMOUNT", textAlign: pw.TextAlign.right, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.SizedBox(width: 20),
                      pw.Expanded(flex: 3, child: pw.Text("DEDUCTIONS", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                      pw.Expanded(flex: 1, child: pw.Text("AMOUNT", textAlign: pw.TextAlign.right, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
                    ],
                  ),
                ),
                pw.SizedBox(height: 5),

                // 4. Finance Body
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    // Earnings Column
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildLineItem("BASIC PAY", basic),
                          if ((earnings['commission'] ?? 0) > 0) _buildLineItem("COMMISSION", (earnings['commission']).toDouble()),
                          if ((earnings['ot'] ?? 0) > 0) _buildLineItem("OVERTIME", (earnings['ot']).toDouble()),
                          if ((earnings['allowance'] ?? 0) > 0) _buildLineItem("ALLOWANCE", (earnings['allowance']).toDouble()),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    // Deductions Column
                    pw.Expanded(
                      child: pw.Column(
                        children: [
                          _buildLineItem("EPF (Employee)", (deductions['epf'] ?? 0).toDouble()),
                          _buildLineItem("SOCSO (Employee)", (deductions['socso'] ?? 0).toDouble()),
                          _buildLineItem("EIS (Employee)", (deductions['eis'] ?? 0).toDouble()),
                          if ((deductions['tax'] ?? 0) > 0) _buildLineItem("PCB / TAX", (deductions['tax']).toDouble()),
                          // 🟢 增加迟到扣款
                          if ((deductions['late'] ?? 0) > 0) _buildLineItem("LATE DEDUCTION", (deductions['late']).toDouble(), isDeduction: true),
                        ],
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 10),
                pw.Divider(),

                // 5. Totals
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Total Earnings", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.Text(gross.toStringAsFixed(2), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                        ],
                      )
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text("Total Deductions", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                          pw.Text(totalDed.toStringAsFixed(2), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                        ],
                      )
                    ),
                  ],
                ),
                pw.SizedBox(height: 20),

                // 6. Net Pay & Employer
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _buildEmployerRow("Employer EPF", data['employer_epf']),
                          _buildEmployerRow("Employer SOCSO", data['employer_socso']),
                          _buildEmployerRow("Employer EIS", data['employer_eis']),
                        ],
                      ),
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text("NET WAGES", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
                          pw.Text("RM ${net.toStringAsFixed(2)}", style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18, color: PdfColors.black)),
                        ],
                      ),
                    ],
                  ),
                ),

                // 7. Attendance Stats (Optional)
                if (data['attendanceStats'] != null) ...[
                  pw.SizedBox(height: 10),
                  pw.Container(
                    padding: const pw.EdgeInsets.all(5),
                    decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                      children: [
                        pw.Text("Work Days: ${data['attendanceStats']['actDays']}", style: const pw.TextStyle(fontSize: 8)),
                        pw.Text("OT Hours: ${data['attendanceStats']['ot']}", style: const pw.TextStyle(fontSize: 8)),
                        pw.Text("Late: ${data['attendanceStats']['late']}m", style: const pw.TextStyle(fontSize: 8)),
                      ],
                    )
                  ),
                ],

                pw.SizedBox(height: 30),
                pw.Center(
                  child: pw.Text("This is a computer generated document. No signature is required.", style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500))
                ),
              ],
            );
          },
        ),
      );

      // Save & Open
      final output = await getTemporaryDirectory();
      final file = File("${output.path}/Payslip_${data['month']}.pdf");
      await file.writeAsBytes(await pdf.save());

      if (mounted) {
        setState(() => _isGenerating = false);
        await OpenFilex.open(file.path);
      }

    } catch (e) {
      debugPrint("PDF Error: $e");
      if (mounted) {
        setState(() => _isGenerating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to generate PDF: $e")));
      }
    }
  }

  // PDF Helpers
  pw.Widget _buildPdfRow(String label, dynamic value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.Text(value?.toString() ?? "-", style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
  }

  pw.Widget _buildLineItem(String label, double amount, {bool isDeduction = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 9, color: isDeduction ? PdfColors.red : PdfColors.black)),
          pw.Text(amount.toStringAsFixed(2), style: pw.TextStyle(fontSize: 9, color: isDeduction ? PdfColors.red : PdfColors.black)),
        ],
      ),
    );
  }

  pw.Widget _buildEmployerRow(String label, dynamic val) {
    final amount = (val ?? 0).toDouble();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Text("$label : ${amount.toStringAsFixed(2)}", style: const pw.TextStyle(fontSize: 8)),
    );
  }
}