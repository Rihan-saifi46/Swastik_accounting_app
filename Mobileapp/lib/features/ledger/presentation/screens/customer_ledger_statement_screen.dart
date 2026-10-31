import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:swastik_mobile_app/core/models/party_model.dart';
import 'package:swastik_mobile_app/core/models/transaction_model.dart';
import 'package:swastik_mobile_app/core/utils/responsive_utils.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/core/services/pdf_service.dart';

class CustomerLedgerStatementScreen extends ConsumerStatefulWidget {
  final PartyModel party;
  final List<TransactionModel> initialTransactions;

  const CustomerLedgerStatementScreen({
    super.key,
    required this.party,
    required this.initialTransactions,
  });

  @override
  ConsumerState<CustomerLedgerStatementScreen> createState() => _CustomerLedgerStatementScreenState();
}

class _CustomerLedgerStatementScreenState extends ConsumerState<CustomerLedgerStatementScreen> {
  String _typeFilter = 'All'; // 'All', 'IN', 'OUT'
  String _dateFilter = 'All Time'; // 'All Time', 'Today', 'This Week', 'This Month'

  Color _getAvatarColorForName(String name) {
    if (name.isEmpty) return const Color(0xFF01565B);
    final code = name.codeUnitAt(0);
    final colors = [
      const Color(0xFF2E5BFF),
      const Color(0xFF8EACCD),
      const Color(0xFF01565B),
      const Color(0xFFDFBA6B),
      const Color(0xFFCFA63A),
    ];
    return colors[code % colors.length];
  }

  void _showPrintDialog(BuildContext context, PartyModel party, List<TransactionModel> filteredTxns) {
    showDialog(
      context: context,
      builder: (context) {
        bool isPrinting = false;
        bool isSaved = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF6EE),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFDFBA6B), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 25,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: const BoxDecoration(
                        color: Color(0xFF01565B),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(18),
                          topRight: Radius.circular(18),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Export Ledger',
                            style: GoogleFonts.montserrat(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white, size: 20),
                            onPressed: () => Navigator.pop(context),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                    if (isPrinting)
                      Container(
                        height: 250,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(color: Color(0xFF01565B)),
                            const SizedBox(height: 20),
                            Text(
                              'Preparing document...',
                              style: GoogleFonts.montserrat(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF5E543F),
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (isSaved)
                      Container(
                        height: 250,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: const BoxDecoration(
                                color: Color(0xFFE8F8F0),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check_circle_rounded, color: Color(0xFF01565B), size: 48),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Ledger Saved!',
                              style: GoogleFonts.montserrat(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF01565B),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'PDF saved successfully',
                              style: GoogleFonts.montserrat(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF01565B),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: Text(
                                'Done',
                                style: GoogleFonts.montserrat(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          children: [
                            Text(
                              'Generate a PDF statement for ${party.name}.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.montserrat(
                                fontSize: 14,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      setDialogState(() => isPrinting = true);
                                      try {
                                        final pdfBytes = await PdfService.generateCustomerLedgerPdf(
                                          party: party,
                                          transactions: filteredTxns,
                                        );
                                        await PdfService.printPdf(pdfBytes);
                                        if (context.mounted) Navigator.pop(context);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Error printing: $e')),
                                          );
                                          setDialogState(() => isPrinting = false);
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.print_rounded, size: 18, color: Color(0xFF01565B)),
                                    label: Text(
                                      'Print A4',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF01565B),
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Color(0xFF01565B), width: 1.5),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      setDialogState(() => isPrinting = true);
                                      try {
                                        final pdfBytes = await PdfService.generateCustomerLedgerPdf(
                                          party: party,
                                          transactions: filteredTxns,
                                        );
                                        final success = await PdfService.savePdfToDownloads(
                                          pdfBytes,
                                          'Ledger_${party.name}_${DateTime.now().millisecondsSinceEpoch}',
                                        );
                                        setDialogState(() {
                                          isPrinting = false;
                                          isSaved = success;
                                        });
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('Error saving PDF: $e')),
                                          );
                                          setDialogState(() => isPrinting = false);
                                        }
                                      }
                                    },
                                    icon: const Icon(Icons.picture_as_pdf, size: 18, color: Colors.white),
                                    label: Text(
                                      'Save PDF',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF01565B),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(partyTransactionsStreamProvider(widget.party.id));
    final isTablet = AppResponsive.isTablet(context);

    // Apply Live Transaction updates if possible, else use initial
    final allTransactions = transactionsAsync.value ?? widget.initialTransactions;
    final partyTxns = allTransactions.where((t) => t.partyId == widget.party.id).toList();

    // 1. Apply Type Filter
    var filteredTxns = partyTxns.where((t) {
      final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
      final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;

      if (_typeFilter == 'IN') return isCredit;
      if (_typeFilter == 'OUT') return isDebit;
      return true;
    }).toList();

    // 2. Apply Date Filter
    final now = TimeUtils.now;
    filteredTxns = filteredTxns.where((t) {
      if (_dateFilter == 'Today') {
        return t.date.year == now.year && t.date.month == now.month && t.date.day == now.day;
      } else if (_dateFilter == 'This Week') {
        final weekAgo = now.subtract(const Duration(days: 7));
        return t.date.isAfter(weekAgo);
      } else if (_dateFilter == 'This Month') {
        return t.date.year == now.year && t.date.month == now.month;
      }
      return true;
    }).toList();

    // 3. Group by date
    final Map<String, List<TransactionModel>> groupedTxns = {};
    final todayStr = DateFormat('yyyy-MM-dd').format(now);
    final yesterdayStr = DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 1)));

    for (final t in filteredTxns) {
      final dateKey = DateFormat('yyyy-MM-dd').format(t.date);
      if (!groupedTxns.containsKey(dateKey)) {
        groupedTxns[dateKey] = [];
      }
      groupedTxns[dateKey]!.add(t);
    }

    final sortedDates = groupedTxns.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      backgroundColor: const Color(0xFFFAF6EE),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF5E543F)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Ledger: ${widget.party.name}',
          style: GoogleFonts.montserrat(
            color: const Color(0xFF5E543F),
            fontWeight: FontWeight.bold,
            fontSize: isTablet ? 22 : 18,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.print_rounded, color: Color(0xFF5E543F)),
            tooltip: 'Print Ledger',
            onPressed: () => _showPrintDialog(context, widget.party, filteredTxns),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isTablet ? 32.0 : 16.0,
              vertical: 8.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Premium Outstanding Balances Header Card
                Container(
                  padding: EdgeInsets.all(isTablet ? 28 : 20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF01565B), Color(0xFF026D73)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF01565B).withOpacity(0.2),
                        blurRadius: 15,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OUTSTANDING BALANCES',
                        style: GoogleFonts.montserrat(
                          fontSize: isTablet ? 13 : 11,
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildBalanceColumn('Cash', '₹', widget.party.cashBalance, isTablet),
                          _buildBalanceColumn('Gold', 'g', widget.party.goldBalanceGrams, isTablet),
                          _buildBalanceColumn('Diamond', 'ct', widget.party.diamondBalanceCarats, isTablet),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Ledger view: Date-wise',
                            style: GoogleFonts.montserrat(
                              fontSize: isTablet ? 13 : 11,
                              color: Colors.white54,
                            ),
                          ),
                          Text(
                            '${filteredTxns.length} entries shown',
                            style: GoogleFonts.montserrat(
                              fontSize: isTablet ? 13 : 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Filters Section (Dropdowns)
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5DEC9).withOpacity(0.6)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _typeFilter,
                            isExpanded: true,
                            icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF735C0F)),
                            style: GoogleFonts.montserrat(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF5E543F),
                            ),
                            items: <String>['All', 'IN', 'OUT'].map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value == 'All' ? 'All Types' : 'Only $value'),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _typeFilter = val);
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5DEC9).withOpacity(0.6)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _dateFilter,
                            isExpanded: true,
                            icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF735C0F)),
                            style: GoogleFonts.montserrat(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF5E543F),
                            ),
                            items: <String>['All Time', 'Today', 'This Week', 'This Month'].map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _dateFilter = val);
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Transactions List
                Expanded(
                  child: filteredTxns.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.receipt_long_rounded,
                                size: isTablet ? 64 : 48,
                                color: const Color(0xFF5E543F).withOpacity(0.3),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No transactions matching filters',
                                style: GoogleFonts.montserrat(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFF5E543F).withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          physics: const BouncingScrollPhysics(),
                          itemCount: sortedDates.length,
                          itemBuilder: (context, dateIndex) {
                            final dateKey = sortedDates[dateIndex];
                            final dayTxns = groupedTxns[dateKey]!;

                            String headerText = '';
                            if (dateKey == todayStr) {
                              headerText = 'Today';
                            } else if (dateKey == yesterdayStr) {
                              headerText = 'Yesterday';
                            } else {
                              final parsedDate = DateTime.parse(dateKey);
                              headerText = DateFormat('EEEE, d MMM yyyy').format(parsedDate);
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 16.0, bottom: 8.0, left: 4.0, right: 4.0),
                                  child: Text(
                                    headerText,
                                    style: GoogleFonts.montserrat(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF735C0F),
                                    ),
                                  ),
                                ),
                                ...dayTxns.map((t) {
                                  final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
                                  final timeStr = DateFormat('hh:mm a').format(t.date);
                                  final amountColor = isCredit ? const Color(0xFF01565B) : const Color(0xFFC62828);
                                  final sign = isCredit ? '+ ' : '- ';

                                  String amountStr = '';
                                  if (t.metalType.isEmpty) {
                                    amountStr = '$sign₹ ${NumberFormat.decimalPattern('en_IN').format(t.cashAmount)}';
                                  } else {
                                    final unit = t.metalType == 'gold' ? 'g' : 'ct';
                                    amountStr = '$sign${t.metalWeight % 1 == 0 ? t.metalWeight.toInt().toString() : t.metalWeight.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $unit';
                                  }

                                  String badgeText = '';
                                  if (t.metalType.isEmpty) {
                                    badgeText = t.paymentMode.name.toUpperCase();
                                  } else if (t.metalType == 'gold') {
                                    badgeText = t.metalPurity.isNotEmpty ? '${t.metalPurity}% Purity' : 'Gold';
                                  } else {
                                    badgeText = t.metalPurity.isNotEmpty ? t.metalPurity : 'Diamond';
                                  }

                                  final initial = t.partyName.isNotEmpty ? t.partyName[0].toUpperCase() : '?';
                                  final avatarBgColor = _getAvatarColorForName(t.partyName);

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: const Color(0xFFE5DEC9).withOpacity(0.5),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.02),
                                          blurRadius: 6,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(14.0),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color: avatarBgColor.withOpacity(0.12),
                                              shape: BoxShape.circle,
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              initial,
                                              style: GoogleFonts.montserrat(
                                                color: avatarBgColor,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        t.typeLabel,
                                                        style: GoogleFonts.montserrat(
                                                          fontSize: 14,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.black87,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                      decoration: BoxDecoration(
                                                        color: const Color(0xFFFAF6EE),
                                                        borderRadius: BorderRadius.circular(6),
                                                        border: Border.all(color: const Color(0xFFE5DEC9)),
                                                      ),
                                                      child: Text(
                                                        badgeText,
                                                        style: GoogleFonts.montserrat(
                                                          fontSize: 9,
                                                          fontWeight: FontWeight.bold,
                                                          color: const Color(0xFF735C0F),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                if (t.notes.isNotEmpty) ...[
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    t.notes,
                                                    style: GoogleFonts.montserrat(
                                                      fontSize: 11,
                                                      color: Colors.black54,
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Text(
                                                amountStr,
                                                style: GoogleFonts.montserrat(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: amountColor,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                timeStr,
                                                style: GoogleFonts.montserrat(
                                                  fontSize: 10,
                                                  color: Colors.black45,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(), // ignore: unnecessary_to_list_in_spreads
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBalanceColumn(String label, String unit, double amount, bool isTablet) {
    final amountAbs = amount.abs();
    final String valStr = (unit == '₹') 
        ? NumberFormat.decimalPattern('en_IN').format(amountAbs)
        : (amountAbs % 1 == 0 ? amountAbs.toInt().toString() : amountAbs.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), ''));
    
    final direction = amount >= 0 ? '(In)' : '(Out)';
    final color = amount >= 0 ? Colors.green[300] : Colors.red[300];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.montserrat(
            fontSize: isTablet ? 12 : 10,
            color: Colors.white60,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$unit $valStr',
              style: GoogleFonts.montserrat(
                fontSize: isTablet ? 18 : 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              direction,
              style: GoogleFonts.montserrat(
                fontSize: isTablet ? 10 : 9,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
