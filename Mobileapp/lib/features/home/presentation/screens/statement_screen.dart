import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:swastik_mobile_app/core/models/transaction_model.dart';
import 'package:swastik_mobile_app/core/utils/responsive_utils.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/core/services/pdf_service.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';
import 'package:swastik_mobile_app/features/home/presentation/widgets/dashboard_print_bottom_sheet.dart';

class TransactionStatementScreen extends ConsumerStatefulWidget {
  final String category; // 'cash', 'online', 'gold', 'diamond'

  const TransactionStatementScreen({
    super.key,
    required this.category,
  });

  @override
  ConsumerState<TransactionStatementScreen> createState() => _TransactionStatementScreenState();
}

class _TransactionStatementScreenState extends ConsumerState<TransactionStatementScreen> {
  String _typeFilter = 'All'; // 'All', 'IN', 'OUT'
  String _dateFilter = 'All Time'; // 'All Time', 'Today', 'This Week', 'This Month'

  String get _periodPrintLabel {
    final now = TimeUtils.now;
    if (_dateFilter == 'Today') {
      return DateFormat('dd MMM yyyy').format(now);
    } else if (_dateFilter == 'This Month') {
      return DateFormat('MMM yyyy').format(now);
    } else if (_dateFilter == 'This Week') {
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      return '${DateFormat('dd MMM').format(startOfWeek)} - ${DateFormat('dd MMM yyyy').format(now)}';
    } else if (_dateFilter == 'All Time') {
      return 'All Time';
    }
    return _dateFilter;
  }

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

  Color get _categoryColor {
    switch (widget.category) {
      case 'cash':
        return const Color(0xFF01565B);
      case 'online':
        return const Color(0xFF2E5BFF);
      case 'gold':
        return const Color(0xFFDFBA6B);
      case 'diamond':
        return const Color(0xFF8EACCD);
      default:
        return const Color(0xFF01565B);
    }
  }

  Gradient get _categoryGradient {
    switch (widget.category) {
      case 'cash':
        return const LinearGradient(
          colors: [Color(0xFF014448), Color(0xFF026D73)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case 'online':
        return const LinearGradient(
          colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case 'gold':
        return const LinearGradient(
          colors: [Color(0xFF9E7C1C), Color(0xFFD4AF37)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      case 'diamond':
        return const LinearGradient(
          colors: [Color(0xFF6B8CAD), Color(0xFF8EACCD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
      default:
        return const LinearGradient(
          colors: [Color(0xFF01565B), Color(0xFF026D73)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
    }
  }

  String get _categoryTitle {
    switch (widget.category) {
      case 'cash':
        return 'Cash Statement';
      case 'online':
        return 'Online (UPI/RTGS) Statement';
      case 'gold':
        return 'Gold Statement';
      case 'diamond':
        return 'Diamond Statement';
      default:
        return 'Statement';
    }
  }

  String get _categoryUnit {
    switch (widget.category) {
      case 'cash':
      case 'online':
        return '₹';
      case 'gold':
        return 'g';
      case 'diamond':
        return 'ct';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(statementTransactionsProvider(_dateFilter));
    final dailyBalancesAsync = ref.watch(dailyBalancesStreamProvider);
    final isTablet = AppResponsive.isTablet(context);

    return Scaffold(
      backgroundColor: const Color(0xFFFAF6EE), // Beautiful warm beige background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF5E543F)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _categoryTitle,
          style: GoogleFonts.montserrat(
            color: const Color(0xFF5E543F),
            fontWeight: FontWeight.bold,
            fontSize: isTablet ? 22 : 18,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.print_rounded, color: Color(0xFF5E543F)),
            tooltip: 'Print Statement',
            onPressed: () async {
              // Extract values for dialog
              final listVal = transactionsAsync.value ?? [];
              final categoryTxns = listVal.where((t) {
                if (widget.category == 'cash') {
                  return t.metalType.isEmpty && t.paymentMode == PaymentMode.cash;
                } else if (widget.category == 'online') {
                  return t.metalType.isEmpty &&
                      (t.paymentMode == PaymentMode.online ||
                          t.paymentMode == PaymentMode.upi ||
                          t.paymentMode == PaymentMode.rtgs);
                } else {
                  return t.metalType == widget.category;
                }
              }).toList();

              double totalBalance = 0.0;
              final summary = ref.read(transactionSummaryProvider).value;
              if (summary != null) {
                if (widget.category == 'cash') {
                  totalBalance = summary.cash;
                } else if (widget.category == 'online') {
                  totalBalance = summary.online;
                } else if (widget.category == 'gold') {
                  totalBalance = summary.gold;
                } else if (widget.category == 'diamond') {
                  totalBalance = summary.diamond;
                }
              } else {
                for (final t in categoryTxns) {
                  final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
                  final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;
                  final val = t.metalType.isEmpty ? t.cashAmount : t.metalWeight;
                  if (isCredit) {
                    totalBalance += val;
                  } else if (isDebit) {
                    totalBalance -= val;
                  }
                }
              }

              var filteredTxns = categoryTxns.where((t) {
                final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
                final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;
                if (_typeFilter == 'IN') return isCredit;
                if (_typeFilter == 'OUT') return isDebit;
                return true;
              }).toList();

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

              String balanceStr = '';
              if (widget.category == 'cash' || widget.category == 'online') {
                balanceStr = '₹ ${NumberFormat.decimalPattern('en_IN').format(totalBalance)}';
              } else {
                balanceStr = '${totalBalance % 1 == 0 ? totalBalance.toInt().toString() : totalBalance.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $_categoryUnit';
              }
              try {
                  final pdfBytes = await PdfService.generateStatementPdf(
                    transactions: List.from(filteredTxns)..sort((a, b) => a.date.compareTo(b.date)),
                    title: 'Statement',
                    subtitle: 'Category: ${widget.category.toUpperCase()}',
                    periodText: 'PERIOD: ${_periodPrintLabel.toUpperCase()}',
                    totalBalance: balanceStr,
                  );
                await PdfService.printPdf(pdfBytes);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error printing: $e')));
                }
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: transactionsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFFDFBA6B)),
        ),
        error: (err, stack) => Center(
          child: Text('Error loading statement: $err'),
        ),
        data: (allTransactions) {
          // 1. Filter by category
          final categoryTxns = allTransactions.where((t) {
            if (widget.category == 'cash') {
              return t.metalType.isEmpty && t.paymentMode == PaymentMode.cash;
            } else if (widget.category == 'online') {
              return t.metalType.isEmpty &&
                  (t.paymentMode == PaymentMode.online ||
                      t.paymentMode == PaymentMode.upi ||
                      t.paymentMode == PaymentMode.rtgs);
            } else {
              return t.metalType == widget.category;
            }
          }).toList();

          // 2. Calculate balance dynamically (read live summary totals)
          double balance = 0.0;
          final summary = ref.watch(transactionSummaryProvider).value;
          if (summary != null) {
            if (widget.category == 'cash') {
              balance = summary.cash;
            } else if (widget.category == 'online') {
              balance = summary.online;
            } else if (widget.category == 'gold') {
              balance = summary.gold;
            } else if (widget.category == 'diamond') {
              balance = summary.diamond;
            }
          } else {
            for (final t in categoryTxns) {
              final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
              final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;
              final val = t.metalType.isEmpty ? t.cashAmount : t.metalWeight;

              if (isCredit) {
                balance += val;
              } else if (isDebit) {
                balance -= val;
              }
            }
          }

          // 3. Apply type filter
          var filteredTxns = categoryTxns.where((t) {
            final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
            final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;

            if (_typeFilter == 'IN') return isCredit;
            if (_typeFilter == 'OUT') return isDebit;
            return true;
          }).toList();

          // 4. Apply date filter
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

          // 5. Format balance string
          String balanceStr = '';
          if (widget.category == 'cash' || widget.category == 'online') {
            balanceStr = '₹ ${NumberFormat.decimalPattern('en_IN').format(balance)}';
          } else {
            balanceStr = '${balance % 1 == 0 ? balance.toInt().toString() : balance.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $_categoryUnit';
          }

          // 6. Group by date
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

          return Center(
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
                // Premium Balance Header Card
                Container(
                  padding: EdgeInsets.all(isTablet ? 28 : 20),
                  decoration: BoxDecoration(
                    gradient: _categoryGradient,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: _categoryColor.withOpacity(0.2),
                        blurRadius: 15,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CURRENT STORE BALANCE',
                        style: GoogleFonts.montserrat(
                          fontSize: isTablet ? 13 : 11,
                          color: widget.category == 'gold' ? Colors.black87.withOpacity(0.6) : Colors.white70,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        balanceStr,
                        style: GoogleFonts.montserrat(
                          fontSize: isTablet ? 32 : 26,
                          fontWeight: FontWeight.bold,
                          color: widget.category == 'gold' ? Colors.black87 : Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Statement view: Date-wise',
                            style: GoogleFonts.montserrat(
                              fontSize: isTablet ? 13 : 11,
                              color: widget.category == 'gold' ? Colors.black87.withOpacity(0.5) : Colors.white54,
                            ),
                          ),
                          Text(
                            '${filteredTxns.length} entries shown',
                            style: GoogleFonts.montserrat(
                              fontSize: isTablet ? 13 : 11,
                              fontWeight: FontWeight.w600,
                              color: widget.category == 'gold' ? Colors.black87.withOpacity(0.7) : Colors.white70,
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
                    // Transaction Type Dropdown Filter
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
                                child: Text(value == 'All' ? 'All Transactions' : 'Only $value'),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _typeFilter = val;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Date Dropdown Filter
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
                                setState(() {
                                  _dateFilter = val;
                                });
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

                            // Determine header text
                            String headerText = '';
                            if (dateKey == todayStr) {
                              headerText = 'Today';
                            } else if (dateKey == yesterdayStr) {
                              headerText = 'Yesterday';
                            } else {
                              final parsedDate = DateTime.parse(dateKey);
                              headerText = DateFormat('EEEE, d MMM yyyy').format(parsedDate);
                            }

                            // Calculate daily closing balance for dateKey
                            double closingVal = 0.0;
                            bool hasSavedBalance = false;

                            if (dailyBalancesAsync.hasValue) {
                              final dailyBalances = dailyBalancesAsync.value ?? [];
                              final matches = dailyBalances.where((b) => b.date == dateKey);
                              final matchingBalance = matches.isNotEmpty ? matches.first : null;
                              if (matchingBalance != null) {
                                hasSavedBalance = true;
                                if (widget.category == 'cash') {
                                  closingVal = matchingBalance.closingCash;
                                } else if (widget.category == 'online') {
                                  closingVal = matchingBalance.closingOnline;
                                } else if (widget.category == 'gold') {
                                  closingVal = matchingBalance.closingGold;
                                } else if (widget.category == 'diamond') {
                                  closingVal = matchingBalance.closingDiamond;
                                }
                              }
                            }

                            if (!hasSavedBalance) {
                              // Dynamic fallback calculation: sum all category transactions occurring on or before dateKey
                              double runningSum = 0.0;
                              for (final t in categoryTxns) {
                                final tDateStr = DateFormat('yyyy-MM-dd').format(t.date);
                                if (tDateStr.compareTo(dateKey) <= 0) {
                                  final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
                                  final isDebit = t.type == TransactionType.payment || t.type == TransactionType.metalOut;
                                  final val = t.metalType.isEmpty ? t.cashAmount : t.metalWeight;
                                  if (isCredit) {
                                    runningSum += val;
                                  } else if (isDebit) {
                                    runningSum -= val;
                                  }
                                }
                              }
                              closingVal = runningSum;
                            }

                            final isToday = dateKey == todayStr;
                            String closingBalanceStr = '';
                            if (!isToday) {
                              final prefix = 'Closing: ';
                              if (widget.category == 'cash' || widget.category == 'online') {
                                closingBalanceStr = '$prefix₹${NumberFormat.decimalPattern('en_IN').format(closingVal)}';
                              } else {
                                closingBalanceStr = '$prefix${closingVal % 1 == 0 ? closingVal.toInt().toString() : closingVal.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $_categoryUnit';
                              }
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Date Header
                                Padding(
                                  padding: const EdgeInsets.only(top: 16.0, bottom: 8.0, left: 4.0, right: 4.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        headerText,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: const Color(0xFF735C0F),
                                        ),
                                      ),
                                      if (closingBalanceStr.isNotEmpty)
                                        Text(
                                          closingBalanceStr,
                                          style: GoogleFonts.montserrat(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF735C0F),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),

                                // Transaction items in a nice Card-style list
                                ...dayTxns.map((t) {
                                  final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
                                  final timeStr = DateFormat('hh:mm a').format(t.date);
                                  final initial = t.partyName.isNotEmpty ? t.partyName[0].toUpperCase() : '?';
                                  final avatarBgColor = _getAvatarColorForName(t.partyName);

                                  // Flow green/red display
                                  final amountColor = isCredit ? const Color(0xFF01565B) : const Color(0xFFC62828);
                                  final sign = isCredit ? '+ ' : '- ';

                                  String amountStr = '';
                                  if (t.metalType.isEmpty) {
                                    amountStr = '$sign₹ ${NumberFormat.decimalPattern('en_IN').format(t.cashAmount)}';
                                  } else {
                                    amountStr = '$sign${t.metalWeight % 1 == 0 ? t.metalWeight.toInt().toString() : t.metalWeight.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $_categoryUnit';
                                  }

                                  // Badge text
                                  String badgeText = '';
                                  if (t.metalType.isEmpty) {
                                    badgeText = t.paymentMode.name.toUpperCase();
                                  } else if (t.metalType == 'gold') {
                                    badgeText = t.metalPurity.isNotEmpty ? '${t.metalPurity}% Purity' : 'Gold';
                                  } else {
                                    badgeText = t.metalPurity.isNotEmpty ? t.metalPurity : 'Diamond';
                                  }

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
                                          // Left: Styled Avatar
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
                                          
                                          // Center: Party details
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        t.partyName,
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
                                          
                                          // Right: Amount, print button, and time
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    amountStr,
                                                    style: GoogleFonts.montserrat(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.bold,
                                                      color: amountColor,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  GestureDetector(
                                                    onTap: () => _showPrintReceiptDialog(context, t, amountStr, badgeText),
                                                    child: Container(
                                                      padding: const EdgeInsets.all(5),
                                                      decoration: BoxDecoration(
                                                        color: const Color(0xFFFAF6EE),
                                                        borderRadius: BorderRadius.circular(6),
                                                        border: Border.all(color: const Color(0xFFE5DEC9), width: 0.5),
                                                      ),
                                                      child: const Icon(
                                                        Icons.print_rounded,
                                                        size: 13,
                                                        color: Color(0xFF735C0F),
                                                      ),
                                                    ),
                                                  ),
                                                  if (ref.watch(isStaffProvider)) ...[
                                                    const SizedBox(width: 6),
                                                    GestureDetector(
                                                      onTap: () => _showChangeDateDialog(t),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(5),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFFFAF6EE),
                                                          borderRadius: BorderRadius.circular(6),
                                                          border: Border.all(color: const Color(0xFFE5DEC9), width: 0.5),
                                                        ),
                                                        child: const Icon(
                                                          Icons.edit_calendar_rounded,
                                                          size: 13,
                                                          color: Color(0xFF735C0F),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                  if (!ref.watch(isStaffProvider)) ...[
                                                    const SizedBox(width: 6),
                                                    GestureDetector(
                                                      onTap: () => _showEditTransactionDialog(t),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(5),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFFFAF6EE),
                                                          borderRadius: BorderRadius.circular(6),
                                                          border: Border.all(color: const Color(0xFFE5DEC9), width: 0.5),
                                                        ),
                                                        child: const Icon(
                                                          Icons.edit_rounded,
                                                          size: 13,
                                                          color: Color(0xFF735C0F),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
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
      );
    },
      ),
    );
  }

  void _showPrintReceiptDialog(
    BuildContext context,
    TransactionModel t,
    String amountStr,
    String badgeText,
  ) {
    final isCredit = t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
    final dateStr = DateFormat('dd MMM yyyy').format(t.date);
    final timeStr = DateFormat('hh:mm a').format(t.date);
    final receiptNo = 'SK-${t.date.millisecondsSinceEpoch.toString().substring(7)}';

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
                    // Header of dialog
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
                            'Receipt Print Preview',
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
                        height: 320,
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(color: Color(0xFF01565B)),
                            const SizedBox(height: 20),
                            Text(
                              'Connecting to printer...',
                              style: GoogleFonts.montserrat(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF5E543F),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Sending receipt to Thermal Printer...',
                              style: GoogleFonts.montserrat(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (isSaved)
                      Container(
                        height: 320,
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
                              child: const Icon(
                                Icons.check_circle_rounded,
                                color: Color(0xFF01565B),
                                size: 48,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Receipt Saved!',
                              style: GoogleFonts.montserrat(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF01565B),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'PDF saved to Downloads folder',
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
                                style: GoogleFonts.montserrat(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      // Simulated Thermal Receipt
                      Padding(
                        padding: const EdgeInsets.all(20.0),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.withOpacity(0.2)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.02),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Store details
                              Center(
                                child: Column(
                                  children: [
                                    Image.asset(
                                      'assets/images/logo.png',
                                      height: 40,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'SWASTIK JEWELS',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF735C0F),
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '------------------------------------------',
                                      style: TextStyle(color: Colors.grey[400]),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Receipt Metadata
                              _buildReceiptRow('Receipt No:', receiptNo),
                              _buildReceiptRow('Date:', '$dateStr  $timeStr'),
                              _buildReceiptRow('Customer Name:', t.partyName),
                              _buildReceiptRow('Type:', isCredit ? 'CREDIT / IN' : 'DEBIT / OUT'),
                              _buildReceiptRow('Category:', widget.category.toUpperCase()),
                              if (badgeText.isNotEmpty)
                                _buildReceiptRow('Particulars:', badgeText),

                              Text(
                                '------------------------------------------',
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                              const SizedBox(height: 8),

                              // Amount / Details Highlight
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFAF6EE),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFE5DEC9)),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'TOTAL AMOUNT:',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF5E543F),
                                      ),
                                    ),
                                    Text(
                                      amountStr,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: isCredit ? const Color(0xFF01565B) : const Color(0xFFC62828),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (t.notes.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Notes: "${t.notes}"',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 16),

                              // Barcode placeholder
                              Center(
                                child: Column(
                                  children: [
                                    Icon(Icons.bar_chart_rounded, size: 40, color: Colors.grey[600]),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Thank you for your business!',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.grey[500],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Print Dialog Actions
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  setDialogState(() {
                                    isPrinting = true;
                                  });
                                  try {
                                    final pdfBytes = await PdfService.generateReceiptPdf(
                                      transaction: t,
                                      amountStr: amountStr,
                                      badgeText: badgeText,
                                    );
                                    await PdfService.printPdf(pdfBytes);
                                    Navigator.pop(context);
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Error printing: $e')),
                                    );
                                    setDialogState(() {
                                      isPrinting = false;
                                    });
                                  }
                                },
                                icon: const Icon(Icons.print_rounded, size: 18, color: Color(0xFF01565B)),
                                label: Text(
                                  'Print',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF01565B),
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFF01565B), width: 1.5),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () async {
                                  setDialogState(() {
                                    isPrinting = true;
                                  });
                                  try {
                                    final pdfBytes = await PdfService.generateReceiptPdf(
                                      transaction: t,
                                      amountStr: amountStr,
                                      badgeText: badgeText,
                                    );
                                    final success = await PdfService.savePdfToDownloads(
                                      pdfBytes,
                                      'Receipt_${receiptNo}',
                                    );
                                    setDialogState(() {
                                      isPrinting = false;
                                      isSaved = success;
                                    });
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Error saving PDF: $e')),
                                    );
                                    setDialogState(() {
                                      isPrinting = false;
                                    });
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
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
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



  void _showDeleteTransactionDialog(TransactionModel txn) {
    showDialog(
      context: context,
      builder: (context) {
        bool isDeleting = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFAF6EE),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFFDFBA6B), width: 1.5),
              ),
              title: Text(
                'Delete Transaction?',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFFC62828),
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Are you sure you want to delete this transaction? This will reverse its impact on the customer\'s outstanding balance.',
                    style: GoogleFonts.montserrat(fontSize: 14, color: Colors.black87),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.withOpacity(0.2)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          txn.typeLabel,
                          style: GoogleFonts.montserrat(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        Text(
                          txn.metalType.isEmpty 
                              ? '₹${txn.cashAmount.toStringAsFixed(2)}' 
                              : '${txn.metalWeight} ${txn.metalType == 'gold' ? 'g' : 'ct'}',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: txn.type == TransactionType.receipt || txn.type == TransactionType.metalIn
                                ? const Color(0xFF2852C6)
                                : const Color(0xFFC62828),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isDeleting ? null : () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.montserrat(fontWeight: FontWeight.bold, color: Colors.grey[700]),
                  ),
                ),
                ElevatedButton(
                  onPressed: isDeleting
                      ? null
                      : () async {
                          setDialogState(() => isDeleting = true);
                          final success = await ref
                              .read(transactionNotifierProvider.notifier)
                              .deleteTransaction(txn);
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success ? 'Transaction deleted successfully' : 'Failed to delete transaction',
                                  style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                                ),
                                backgroundColor: success ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                              ),
                            );
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC62828),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: isDeleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                        )
                      : Text(
                          'Delete',
                          style: GoogleFonts.montserrat(fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showChangeDateDialog(TransactionModel txn) {
    DateTime selectedDate = txn.date;

    showDialog(
      context: context,
      builder: (context) {
        bool isSaving = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isCredit = txn.type == TransactionType.receipt || txn.type == TransactionType.metalIn;
            final amountColor = isCredit ? const Color(0xFF01565B) : const Color(0xFFC62828);
            final sign = isCredit ? '+ ' : '- ';

            String amountStr = '';
            if (txn.metalType.isEmpty) {
              amountStr = '$sign₹ ${NumberFormat.decimalPattern('en_IN').format(txn.cashAmount)}';
            } else {
              final unit = txn.metalType == 'gold' ? 'g' : 'ct';
              amountStr = '$sign${txn.metalWeight % 1 == 0 ? txn.metalWeight.toInt().toString() : txn.metalWeight.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} $unit';
            }

            return AlertDialog(
              backgroundColor: const Color(0xFFFAF6EE),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFFDFBA6B), width: 1.5),
              ),
              title: Row(
                children: [
                  const Icon(Icons.edit_calendar_rounded, color: Color(0xFF735C0F), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    'Change Date',
                    style: GoogleFonts.montserrat(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF735C0F),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE5DEC9)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  txn.partyName,
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: Colors.black87,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                amountStr,
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: amountColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFAF6EE),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                                ),
                                child: Text(
                                  txn.typeLabel,
                                  style: GoogleFonts.montserrat(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: const Color(0xFF735C0F),
                                  ),
                                ),
                              ),
                              if (txn.notes.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    txn.notes,
                                    style: GoogleFonts.montserrat(
                                      fontSize: 11,
                                      color: Colors.black54,
                                      fontStyle: FontStyle.italic,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'TRANSACTION DATE & TIME',
                      style: GoogleFonts.montserrat(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[600],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        title: Text(
                          'Selected Date & Time',
                          style: GoogleFonts.montserrat(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[600],
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            DateFormat('dd MMM yyyy • hh:mm a').format(selectedDate),
                            style: GoogleFonts.montserrat(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.calendar_today,
                          color: Color(0xFF6B5800),
                          size: 20,
                        ),
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (date != null) {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.fromDateTime(selectedDate),
                            );
                            if (time != null) {
                              setDialogState(() {
                                selectedDate = DateTime(
                                  date.year,
                                  date.month,
                                  date.day,
                                  time.hour,
                                  time.minute,
                                );
                              });
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: isSaving ? null : () => Navigator.pop(context),
                      child: Text(
                        'Cancel',
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: isSaving ? null : () async {
                        setDialogState(() => isSaving = true);
                        final success = await ref
                            .read(transactionNotifierProvider.notifier)
                            .updateTransactionDate(
                              txn: txn,
                              newDate: selectedDate,
                            );
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                success
                                    ? 'Transaction date updated successfully'
                                    : 'Failed to update transaction date',
                                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                              ),
                              backgroundColor: success
                                  ? const Color(0xFF2E7D32)
                                  : const Color(0xFFC62828),
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6B5800),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      child: isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Text(
                              'Save Date',
                              style: GoogleFonts.montserrat(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEditTransactionDialog(TransactionModel txn) {
    final amountController = TextEditingController(
      text: txn.metalType.isEmpty ? txn.cashAmount.toString() : txn.metalWeight.toString(),
    );
    final notesController = TextEditingController(text: txn.notes);
    
    // Gold Purity field
    final purityController = TextEditingController(
      text: txn.metalType == 'gold' ? txn.metalPurity : '',
    );
    
    // Diamond Pieces field
    String initialPieces = txn.metalPurity;
    if (initialPieces.endsWith(' p')) {
      initialPieces = initialPieces.replaceAll(' p', '');
    }
    final piecesController = TextEditingController(
      text: txn.metalType == 'diamond' ? initialPieces : '',
    );

    DateTime selectedDate = txn.date;
    PaymentMode selectedPaymentMode = txn.paymentMode == PaymentMode.online ? PaymentMode.upi : txn.paymentMode;

    showDialog(
      context: context,
      builder: (context) {
        bool isSaving = false;
        bool isIn = txn.type == TransactionType.receipt || txn.type == TransactionType.metalIn;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFAF6EE),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFFDFBA6B), width: 1.5),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      'TRANSACTION TYPE',
                      style: GoogleFonts.montserrat(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[600],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<bool>(
                      value: isIn,
                      dropdownColor: const Color(0xFFFAF6EE),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                        ),
                      ),
                      style: GoogleFonts.montserrat(
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                        fontSize: 14,
                      ),
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() {
                            isIn = val;
                          });
                        }
                      },
                      items: const [
                        DropdownMenuItem<bool>(
                          value: true,
                          child: Row(
                            children: [
                              Icon(Icons.arrow_downward_rounded, color: Color(0xFF2E7D32), size: 18),
                              SizedBox(width: 8),
                              Text('In', style: TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        DropdownMenuItem<bool>(
                          value: false,
                          child: Row(
                            children: [
                              Icon(Icons.arrow_upward_rounded, color: Color(0xFFC62828), size: 18),
                              SizedBox(width: 8),
                              Text('Out', style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (txn.metalType.isEmpty) ...[
                      // MONEY CATEGORY: Cash/UPI/RTGS dropdown + Amount
                      Text(
                        'PAYMENT MODE',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<PaymentMode>(
                        value: selectedPaymentMode,
                        dropdownColor: const Color(0xFFFAF6EE),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                          fontSize: 14,
                        ),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedPaymentMode = val;
                            });
                          }
                        },
                        items: const [
                          DropdownMenuItem<PaymentMode>(
                            value: PaymentMode.cash,
                            child: Text('Cash'),
                          ),
                          DropdownMenuItem<PaymentMode>(
                            value: PaymentMode.upi,
                            child: Text('UPI'),
                          ),
                          DropdownMenuItem<PaymentMode>(
                            value: PaymentMode.rtgs,
                            child: Text('RTGS'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'AMOUNT (₹)',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                      ),
                    ] else if (txn.metalType == 'gold') ...[
                      // GOLD CATEGORY: Weight + Purity (Text input field for % or karat)
                      Text(
                        'WEIGHT (g)',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'PURITY',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: purityController,
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                      ),
                    ] else if (txn.metalType == 'diamond') ...[
                      // DIAMOND CATEGORY: Weight (ct) + Pieces (peace)
                      Text(
                        'WEIGHT (ct)',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'PIECES',
                        style: GoogleFonts.montserrat(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[600],
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: piecesController,
                        keyboardType: TextInputType.number,
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'PARTICULARS / NOTES',
                      style: GoogleFonts.montserrat(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[600],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: notesController,
                      textCapitalization: TextCapitalization.characters,
                      maxLines: 3,
                      style: GoogleFonts.montserrat(fontSize: 13, fontWeight: FontWeight.w500),
                      decoration: InputDecoration(
                        hintText: 'Add description...',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: Color(0xFF6B5800), width: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFDFBA6B).withOpacity(0.5)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        title: Text(
                          'Date & Time',
                          style: GoogleFonts.montserrat(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey[600]),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            DateFormat('dd MMM yyyy • hh:mm a').format(selectedDate),
                            style: GoogleFonts.montserrat(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                        trailing: const Icon(Icons.calendar_today, color: Color(0xFF6B5800), size: 20),
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: selectedDate.subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 1)),
                          );
                          if (date != null) {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.fromDateTime(selectedDate),
                            );
                            if (time != null) {
                              setDialogState(() {
                                selectedDate = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                              });
                            }
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (confirmContext) {
                            bool isDeleting = false;
                            return StatefulBuilder(
                              builder: (confirmContext, setConfirmState) {
                                return AlertDialog(
                                  backgroundColor: const Color(0xFFFAF6EE),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    side: const BorderSide(color: Color(0xFFDFBA6B), width: 1.5),
                                  ),
                                  title: Text(
                                    'Delete Transaction?',
                                    style: GoogleFonts.montserrat(
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFFC62828),
                                    ),
                                  ),
                                  content: Text(
                                    'Are you sure you want to delete this transaction? This will reverse its impact on the customer\'s outstanding balance.',
                                    style: GoogleFonts.montserrat(fontSize: 14, color: Colors.black87),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: isDeleting
                                          ? null
                                          : () => Navigator.pop(confirmContext),
                                      child: Text(
                                        'Cancel',
                                        style: GoogleFonts.montserrat(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey[700],
                                        ),
                                      ),
                                    ),
                                    ElevatedButton(
                                      onPressed: isDeleting
                                          ? null
                                          : () async {
                                              setConfirmState(() => isDeleting = true);
                                              final success = await ref
                                                  .read(transactionNotifierProvider.notifier)
                                                  .deleteTransaction(txn);
                                              if (mounted) {
                                                Navigator.pop(confirmContext);
                                                Navigator.pop(context);
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      success
                                                          ? 'Transaction deleted successfully'
                                                          : 'Failed to delete transaction',
                                                      style: GoogleFonts.montserrat(
                                                          fontWeight: FontWeight.w600),
                                                    ),
                                                    backgroundColor: success
                                                        ? const Color(0xFF2E7D32)
                                                        : const Color(0xFFC62828),
                                                  ),
                                                );
                                              }
                                            },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFC62828),
                                        shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: isDeleting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<Color>(
                                                        Colors.white),
                                              ),
                                            )
                                          : Text(
                                              'Delete',
                                              style: GoogleFonts.montserrat(
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white),
                                            ),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                      },
                      child: Text(
                        'Delete',
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFC62828),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: isSaving ? null : () => Navigator.pop(context),
                          child: Text(
                            'Cancel',
                            style: GoogleFonts.montserrat(
                                fontWeight: FontWeight.bold, color: Colors.grey[700]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: isSaving
                              ? null
                              : () async {
                                  final val = double.tryParse(amountController.text) ?? 0.0;
                                  if (val <= 0) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Please enter a valid amount or weight')),
                                    );
                                    return;
                                  }

                                  setDialogState(() => isSaving = true);

                                  final isMetal = txn.metalType.isNotEmpty;
                                  final TransactionType finalType = isMetal
                                      ? (isIn ? TransactionType.metalIn : TransactionType.metalOut)
                                      : (isIn ? TransactionType.receipt : TransactionType.payment);

                                  String finalPurity = txn.metalPurity;
                                  if (txn.metalType == 'gold') {
                                    finalPurity = purityController.text.trim();
                                  } else if (txn.metalType == 'diamond') {
                                    finalPurity = '${piecesController.text.trim()} p';
                                  }

                                  final newTx = TransactionModel(
                                    id: txn.id,
                                    partyId: txn.partyId,
                                    partyName: txn.partyName,
                                    partyPhone: txn.partyPhone,
                                    type: finalType,
                                    paymentMode: txn.metalType.isEmpty ? selectedPaymentMode : txn.paymentMode,
                                    cashAmount: txn.metalType.isEmpty ? val : txn.cashAmount,
                                    metalType: txn.metalType,
                                    metalWeight: txn.metalType.isNotEmpty ? val : txn.metalWeight,
                                    metalPurity: finalPurity,
                                    notes: notesController.text,
                                    date: selectedDate,
                                    createdAt: txn.createdAt,
                                  );

                                  final success = await ref
                                      .read(transactionNotifierProvider.notifier)
                                      .updateTransaction(oldTx: txn, newTx: newTx);

                                  if (mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          success
                                              ? 'Transaction updated successfully'
                                              : 'Failed to update transaction',
                                          style: GoogleFonts.montserrat(
                                              fontWeight: FontWeight.w600),
                                        ),
                                        backgroundColor: success
                                            ? const Color(0xFF2E7D32)
                                            : const Color(0xFFC62828),
                                      ),
                                    );
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4A3E1F),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor:
                                          AlwaysStoppedAnimation<Color>(Colors.white)),
                                )
                              : Text(
                                  'Save',
                                  style: GoogleFonts.montserrat(
                                      fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildReceiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: GoogleFonts.montserrat(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.montserrat(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
