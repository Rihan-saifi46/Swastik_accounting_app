import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:swastik_mobile_app/core/models/party_model.dart';
import 'package:swastik_mobile_app/core/models/transaction_model.dart';
import 'package:swastik_mobile_app/core/models/txn_summary_model.dart';
import 'package:swastik_mobile_app/core/utils/responsive_utils.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';
import 'package:swastik_mobile_app/core/utils/formatters.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/features/parties/providers/party_providers.dart';
import 'package:swastik_mobile_app/features/parties/presentation/widgets/quick_add_party_bottom_sheet.dart';
import 'package:intl/intl.dart';
import 'package:swastik_mobile_app/features/home/presentation/screens/statement_screen.dart';
import 'package:swastik_mobile_app/features/home/presentation/widgets/custom_filter_sheet.dart';
import 'package:swastik_mobile_app/features/home/presentation/widgets/dashboard_print_bottom_sheet.dart';
import 'package:swastik_mobile_app/features/settings/presentation/widgets/avatar_widget.dart';
import 'package:swastik_mobile_app/features/settings/providers/profile_providers.dart';
import 'package:swastik_mobile_app/features/auth/providers/user_profiles_provider.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';
import 'package:swastik_mobile_app/features/settings/presentation/screens/device_management_screen.dart';
import 'package:swastik_mobile_app/core/services/pdf_service.dart';
import 'package:swastik_mobile_app/features/reminders/providers/reminder_providers.dart';
import 'package:swastik_mobile_app/features/reminders/providers/appointment_providers.dart';
import 'package:swastik_mobile_app/features/reminders/providers/reminder_navigation_provider.dart';
import 'package:swastik_mobile_app/features/navigation/presentation/providers/navigation_provider.dart';
import 'package:swastik_mobile_app/features/parties/presentation/widgets/quick_party_info_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Search query state for Tablet Transaction Table
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _selectedTableFilter = 'Today'; // Default is 'Today'
  CustomFilterResult? _customFilterResult;

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      setState(() {});
    });
    // Push the initial filter ('Today') to the server-side table provider once
    // the first frame is ready so it fetches only today's window, not everything.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncFilterToProvider();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Translates the current filter selection into a server query and pushes it
  /// to [homeTxnQueryProvider]. Date filters use a ±1 day padded window (the
  /// UI's [_applyDateFilter] trims to the exact days, so padding is safe and
  /// immune to any timezone edge at the day boundary); 'All' pages in batches.
  void _syncFilterToProvider() {
    ref.read(homeTransactionsProvider.notifier).setQuery(_computeQuery());
  }

  HomeTxnQuery _computeQuery() {
    final now = TimeUtils.now;
    DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
    const pad = Duration(days: 1);

    switch (_selectedTableFilter) {
      case 'Today':
        final s = dayStart(now);
        return HomeTxnQuery(from: s.subtract(pad), to: s.add(pad + pad));
      case 'This Week':
        final startOfWeek = dayStart(now.subtract(Duration(days: now.weekday - 1)));
        return HomeTxnQuery(
          from: startOfWeek.subtract(pad),
          to: dayStart(now).add(pad + pad),
        );
      case 'This Month':
        final startOfMonth = DateTime(now.year, now.month, 1);
        final startOfNextMonth = DateTime(now.year, now.month + 1, 1);
        return HomeTxnQuery(
          from: startOfMonth.subtract(pad),
          to: startOfNextMonth.add(pad),
        );
      case 'Custom':
        final r = _customFilterResult;
        if (r != null) {
          if (r.type == 'date' && r.date != null) {
            final s = dayStart(r.date!);
            return HomeTxnQuery(from: s.subtract(pad), to: s.add(pad + pad));
          }
          if (r.type == 'date_range' && r.date != null && r.endDate != null) {
            return HomeTxnQuery(
              from: dayStart(r.date!).subtract(pad),
              to: dayStart(r.endDate!).add(pad + pad),
            );
          }
          if (r.type == 'month_year' && r.month != null && r.year != null) {
            final startOfMonth = DateTime(r.year!, r.month!, 1);
            final startOfNextMonth = DateTime(r.year!, r.month! + 1, 1);
            return HomeTxnQuery(
              from: startOfMonth.subtract(pad),
              to: startOfNextMonth.add(pad),
            );
          }
        }
        // 'month_only' (all years) and any incomplete custom selection can't be
        // expressed as a single date window — fall back to loading everything.
        return const HomeTxnQuery(all: true);
      case 'All':
      default:
        return const HomeTxnQuery(all: true);
    }
  }

  /// Adapts the paginated [HomeTxnState] to the [AsyncValue] shape the existing
  /// table widgets already consume, so their loading/empty/data branches keep
  /// working unchanged. Last-good data is preserved during background refreshes.
  AsyncValue<List<TransactionModel>> _asAsync(HomeTxnState s) {
    if (s.error != null && s.items.isEmpty) {
      return AsyncError(s.error!, StackTrace.current);
    }
    if (s.isLoading && s.items.isEmpty) {
      return const AsyncValue.loading();
    }
    return AsyncData(s.items);
  }

  /// "Load more" control shown under the table when more "All" batches exist.
  Widget _buildLoadMoreButton(HomeTxnState txState) {
    if (!txState.hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: TextButton.icon(
          onPressed: txState.isLoadingMore
              ? null
              : () => ref.read(homeTransactionsProvider.notifier).loadMore(),
          icon: txState.isLoadingMore
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more_rounded, size: 18),
          label: Text(
            txState.isLoadingMore ? 'Loading…' : 'Load more',
            style: GoogleFonts.montserrat(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF735C0F),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleRefresh() async {
    ref.invalidate(partiesStreamProvider);
    try {
      // Actually await the latest data so a pull-to-refresh reflects the newest
      // entries and totals. The table window, the summary totals and the parties
      // list are refreshed together; a generous cap still guarantees the spinner
      // always dismisses even on a slow/failed network.
      await Future.wait([
        ref.read(homeTransactionsProvider.notifier).refresh(),
        ref.read(transactionSummaryProvider.notifier).refresh(),
        ref.read(partiesStreamProvider.future),
      ]).timeout(const Duration(seconds: 8));
    } catch (_) {
      // Gracefully handle timeout or network error to ensure spinner always dismisses
    }
  }

  PopupMenuItem<String> _buildFilterMenuItem(
    String value,
    String label,
    IconData icon,
  ) {
    final isSelected = _selectedTableFilter == value;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: isSelected
                ? const Color(0xFF735C0F)
                : const Color(0xFF5E543F).withOpacity(0.7),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: GoogleFonts.montserrat(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? const Color(0xFF735C0F) : Colors.black87,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            const Icon(Icons.check_rounded, size: 16, color: Color(0xFF735C0F)),
          ],
        ],
      ),
    );
  }

  /// Returns the display label for the current filter.
  String get _filterDisplayLabel {
    if (_selectedTableFilter == 'Custom' && _customFilterResult != null) {
      return _customFilterResult!.displayLabel;
    }
    return _selectedTableFilter;
  }

  /// Returns a nicely formatted period string for the PDF print output.
  String get _periodPrintLabel {
    final now = TimeUtils.now;
    if (_selectedTableFilter == 'Custom' && _customFilterResult != null) {
      return _customFilterResult!.displayLabel;
    } else if (_selectedTableFilter == 'Today') {
      return DateFormat('dd MMM yyyy').format(now);
    } else if (_selectedTableFilter == 'This Month') {
      return DateFormat('MMM yyyy').format(now);
    } else if (_selectedTableFilter == 'This Week') {
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      return '${DateFormat('dd MMM').format(startOfWeek)} - ${DateFormat('dd MMM yyyy').format(now)}';
    } else if (_selectedTableFilter == 'All') {
      return 'All Time';
    }
    return _selectedTableFilter;
  }

  /// Opens the premium custom filter bottom sheet.
  Future<void> _openCustomFilterSheet() async {
    final result = await showModalBottomSheet<CustomFilterResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CustomFilterSheet(initial: _customFilterResult),
    );
    if (result != null && mounted) {
      setState(() {
        _selectedTableFilter = 'Custom';
        _customFilterResult = result;
      });
      _syncFilterToProvider();
    }
  }

  /// Applies date filtering to a list of transactions based on
  /// the current [_selectedTableFilter] and [_customFilterResult].
  List<TransactionModel> _applyDateFilter(List<TransactionModel> transactions) {
    final now = TimeUtils.now;
    return transactions.where((t) {
      if (_selectedTableFilter == 'Today') {
        return t.date.year == now.year &&
            t.date.month == now.month &&
            t.date.day == now.day;
      } else if (_selectedTableFilter == 'This Week') {
        final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
        final startOfToday = DateTime(
          startOfWeek.year,
          startOfWeek.month,
          startOfWeek.day,
        );
        final txnDate = DateTime(t.date.year, t.date.month, t.date.day);
        return txnDate.isAfter(
              startOfToday.subtract(const Duration(days: 1)),
            ) &&
            txnDate.isBefore(
              DateTime(
                now.year,
                now.month,
                now.day,
              ).add(const Duration(days: 1)),
            );
      } else if (_selectedTableFilter == 'This Month') {
        return t.date.year == now.year && t.date.month == now.month;
      } else if (_selectedTableFilter == 'Custom' &&
          _customFilterResult != null) {
        final r = _customFilterResult!;
        switch (r.type) {
          case 'date':
            if (r.date != null) {
              return t.date.year == r.date!.year &&
                  t.date.month == r.date!.month &&
                  t.date.day == r.date!.day;
            }
            return true;
          case 'date_range':
            if (r.date != null && r.endDate != null) {
              final txnDate = DateTime(t.date.year, t.date.month, t.date.day);
              final startDate = DateTime(r.date!.year, r.date!.month, r.date!.day);
              final endDate = DateTime(r.endDate!.year, r.endDate!.month, r.endDate!.day);
              
              return (txnDate.isAtSameMomentAs(startDate) || txnDate.isAfter(startDate)) &&
                     (txnDate.isAtSameMomentAs(endDate) || txnDate.isBefore(endDate));
            }
            return true;
          case 'month_year':
            if (r.month != null && r.year != null) {
              return t.date.year == r.year && t.date.month == r.month;
            }
            return true;
          case 'month_only':
            if (r.month != null) {
              return t.date.month == r.month;
            }
            return true;
          default:
            return true;
        }
      }
      return true; // 'All'
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = AppResponsive.isTablet(context);

    // Home table data now comes from the server-side filtered / batched provider
    // (only the current window is fetched), adapted to the AsyncValue shape the
    // table widgets already consume.
    final txState = ref.watch(homeTransactionsProvider);
    final transactionsAsync = _asAsync(txState);

    // Summary cards read the running totals from the server-side aggregation
    // (`/transactions/summary`) instead of re-downloading the whole transactions
    // collection to sum them on the device. The formula on the server mirrors
    // _computeCategoryTotal exactly, and a mutation pushes an optimistic delta
    // (see TransactionNotifier) so the cards update the instant an entry is saved.
    final TxnSummary summary =
        ref.watch(transactionSummaryProvider).value ?? TxnSummary.zero;
    final double cashVal = summary.cash;
    final double onlineVal = summary.online;
    final double goldVal = summary.gold;
    final double diamondVal = summary.diamond;

    final String displayCash =
        '₹ ${NumberFormat.decimalPattern('en_IN').format(cashVal)}';
    final String displayOnline =
        '₹ ${NumberFormat.decimalPattern('en_IN').format(onlineVal)}';
    final String displayGold =
        '${goldVal % 1 == 0 ? goldVal.toInt().toString() : goldVal.toStringAsFixed(3).replaceAll(RegExp(r"\.?0+$"), "")} g';
    final String displayDiamond =
        '${diamondVal % 1 == 0 ? diamondVal.toInt().toString() : diamondVal.toStringAsFixed(2).replaceAll(RegExp(r"\.?0+$"), "")} ct';

    if (isTablet) {
      return _buildTabletHomeScreen(
        transactionsAsync: transactionsAsync,
        cash: displayCash,
        online: displayOnline,
        gold: displayGold,
        diamond: displayDiamond,
      );
    }

    // Existing mobile layout
    return Container(
      color: const Color(0xFFFAF6EE),
      child: SafeArea(
        child: RefreshIndicator(
          onRefresh: _handleRefresh,
          color: const Color(0xFFD4B13B),
          backgroundColor: const Color(0xFFFAF6EE),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildProfileHeader(),
                const SizedBox(height: 24),
                _buildBalancesGrid(
                  cash: displayCash,
                  online: displayOnline,
                  gold: displayGold,
                  diamond: displayDiamond,
                ),
                const SizedBox(height: 24),
                _buildRecentTransactions(),
                const SizedBox(height: 80), // Padding for bottom FAB
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // TABLET SCREEN LAYOUT
  // ==========================================

  Widget _buildTabletHomeScreen({
    required AsyncValue<List<TransactionModel>> transactionsAsync,
    required String cash,
    required String online,
    required String gold,
    required String diamond,
  }) {
    final dateStr = DateFormat('EEEE, d MMMM yyyy').format(TimeUtils.now);

    return GestureDetector(
      onTap: () {
        if (_searchFocusNode.hasFocus) {
          _searchFocusNode.unfocus();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: Container(
        color: const Color(0xFFFAF6EE), // Beautiful warm beige/cream background
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: _handleRefresh,
            color: const Color(0xFFD4B13B),
            backgroundColor: const Color(0xFFFAF6EE),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 28.0,
                vertical: 24.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Section (Date and New Entry button)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        dateStr,
                        style: GoogleFonts.montserrat(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: const Color(
                            0xFF735C0F,
                          ), // Olive-gold text matching the screenshot
                        ),
                      ),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _showSetAppointmentDialog(
                              context,
                              isTablet: true,
                            ),
                            icon: const Icon(
                              Icons.calendar_today_outlined,
                              color: Color(0xFF735C0F),
                              size: 18,
                            ),
                            label: Text(
                              'Set Appointment',
                              style: GoogleFonts.montserrat(
                                color: const Color(0xFF735C0F),
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFAF6EE),
                              elevation: 1,
                              side: const BorderSide(
                                color: Color(0xFFE5DEC9),
                                width: 1.5,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: () {
                              showDialog(
                                context: context,
                                barrierDismissible: true,
                                builder: (context) => const Dialog(
                                  backgroundColor: Colors.transparent,
                                  child: TabletQuickAddEntryDialog(),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.add,
                              color: Color(0xFF01565B),
                              size: 18,
                            ),
                            label: Text(
                              'New Entry',
                              style: GoogleFonts.montserrat(
                                color: const Color(0xFF01565B),
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(
                                0xFFDFBA6B,
                              ), // Gold background
                              elevation: 2,
                              shadowColor: Colors.black.withOpacity(0.1),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
  
                  // Summary Cards Grid (4 Cards Row)
                  _buildTabletSummaryCards(
                    cash: cash,
                    online: online,
                    gold: gold,
                    diamond: diamond,
                  ),
                  const SizedBox(height: 28),
  
                  // Recent Transactions Table inside a beautifully styled Card
                  _buildTabletTransactionsTable(transactionsAsync),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabletSummaryCards({
    required String cash,
    required String online,
    required String gold,
    required String diamond,
  }) {
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    if (isPortrait) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildTabletCard(
                  label: 'TOTAL CASH',
                  value: cash,
                  accentColor: const Color(0xFF01565B),
                  icon: Icons.payments_outlined,
                  iconColor: const Color(0xFF01565B),
                  iconBgColor: const Color(0xFFE8F8F0),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const TransactionStatementScreen(category: 'cash'),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildTabletCard(
                  label: 'TOTAL UPI/RTGS',
                  value: online,
                  accentColor: const Color(0xFF2E5BFF),
                  icon: Icons.account_balance_rounded,
                  iconColor: const Color(0xFF2E5BFF),
                  iconBgColor: const Color(0xFFE6F0FA),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const TransactionStatementScreen(category: 'online'),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildTabletCard(
                  label: 'TOTAL GOLD',
                  value: gold,
                  accentColor: const Color(0xFFDFBA6B),
                  icon: Icons.widgets_rounded,
                  iconColor: const Color(0xFF735C0F),
                  iconBgColor: const Color(0xFFFFF9E6),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const TransactionStatementScreen(category: 'gold'),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildTabletCard(
                  label: 'TOTAL DIAMOND',
                  value: diamond,
                  accentColor: const Color(0xFF8EACCD),
                  icon: Icons.diamond_rounded,
                  iconColor: const Color(0xFF4F709C),
                  iconBgColor: const Color(0xFFE3EDF7),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          const TransactionStatementScreen(category: 'diamond'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: _buildTabletCard(
            label: 'TOTAL CASH',
            value: cash,
            accentColor: const Color(0xFF01565B),
            icon: Icons.payments_outlined,
            iconColor: const Color(0xFF01565B),
            iconBgColor: const Color(0xFFE8F8F0),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const TransactionStatementScreen(category: 'cash'),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildTabletCard(
            label: 'TOTAL UPI/RTGS',
            value: online,
            accentColor: const Color(0xFF2E5BFF),
            icon: Icons.account_balance_rounded,
            iconColor: const Color(0xFF2E5BFF),
            iconBgColor: const Color(0xFFE6F0FA),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const TransactionStatementScreen(category: 'online'),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildTabletCard(
            label: 'TOTAL GOLD',
            value: gold,
            accentColor: const Color(0xFFDFBA6B),
            icon: Icons.widgets_rounded,
            iconColor: const Color(0xFF735C0F),
            iconBgColor: const Color(0xFFFFF9E6),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const TransactionStatementScreen(category: 'gold'),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildTabletCard(
            label: 'TOTAL DIAMOND',
            value: diamond,
            accentColor: const Color(0xFF8EACCD),
            icon: Icons.diamond_rounded,
            iconColor: const Color(0xFF4F709C),
            iconBgColor: const Color(0xFFE3EDF7),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const TransactionStatementScreen(category: 'diamond'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabletCard({
    required String label,
    required String value,
    required Color accentColor,
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 104,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFE5DEC9).withOpacity(0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            // Left colored accent strip
            Container(width: 4, color: accentColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          label,
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            color: const Color(0xFF5E543F).withOpacity(0.8),
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, color: iconColor, size: 16),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          value,
                          style: GoogleFonts.montserrat(
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFF01565B).withOpacity(0.3),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF01565B),
                            size: 16,
                          ),
                        ),
                      ],
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

  Widget _buildTabletTransactionsTable(
    AsyncValue<List<TransactionModel>> transactionsAsync,
  ) {
    final txState = ref.watch(homeTransactionsProvider);
    final transactions = transactionsAsync.value ?? [];

    // 1. Date filter (uses shared _applyDateFilter)
    final dateFilteredTransactions = _applyDateFilter(transactions);

    // 2. Search query filter
    final filtered = dateFilteredTransactions.where((t) {
      final query = _searchQuery.toLowerCase().trim();
      if (query.isEmpty) return true;
      return t.partyName.toLowerCase().contains(query) ||
          (t.notes?.toLowerCase().contains(query) ?? false) ||
          t.metalType.toLowerCase().contains(query);
    }).toList();

    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;
    final bool isSearchActive =
        isPortrait && (_searchFocusNode.hasFocus || _searchQuery.isNotEmpty);
    final int dateFlex = 2;
    final int nameFlex = isPortrait ? 4 : 3;
    final int categoryFlex = 2;
    final int amountFlex = 2;
    final int notesFlex = isPortrait ? 3 : 3;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE5DEC9).withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Table Title, Search Bar and Filter row
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (!isSearchActive) ...[
                  Text(
                    'Recent Transaction',
                    style: GoogleFonts.montserrat(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF01565B),
                    ),
                  ),
                  Row(
                    children: [
                      // Collapsible Search Field
                      GestureDetector(
                        onTap: () {
                          if (!_searchFocusNode.hasFocus) {
                            _searchFocusNode.requestFocus();
                          }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOutCubic,
                          width:
                              (!isPortrait ||
                                  _searchFocusNode.hasFocus ||
                                  _searchQuery.isNotEmpty)
                              ? 240.0
                              : 40.0,
                          height: 40,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAF6EE),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5DEC9)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            onChanged: (val) {
                              setState(() {
                                _searchQuery = val;
                              });
                            },
                            style: GoogleFonts.montserrat(fontSize: 13),
                            textAlignVertical: TextAlignVertical.center,
                            decoration: InputDecoration(
                              hintText:
                                  (!isPortrait ||
                                      _searchFocusNode.hasFocus ||
                                      _searchQuery.isNotEmpty)
                                  ? 'Search'
                                  : '',
                              hintStyle: GoogleFonts.montserrat(
                                color: const Color(0xFF5E543F).withOpacity(0.6),
                                fontSize: 13,
                              ),
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 18,
                                color: Color(0xFF5E543F),
                              ),
                              suffixIcon:
                                  ((!isPortrait || _searchFocusNode.hasFocus) &&
                                      _searchQuery.isNotEmpty)
                                  ? IconButton(
                                      icon: const Icon(
                                        Icons.clear_rounded,
                                        size: 16,
                                        color: Color(0xFF5E543F),
                                      ),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() {
                                          _searchQuery = '';
                                        });
                                        if (isPortrait) {
                                          _searchFocusNode.unfocus();
                                        }
                                      },
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    )
                                  : null,
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Filter Button
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'Custom') {
                            _openCustomFilterSheet();
                          } else {
                            setState(() {
                              _selectedTableFilter = value;
                              _customFilterResult = null;
                            });
                            _syncFilterToProvider();
                          }
                        },
                        itemBuilder: (context) => [
                          _buildFilterMenuItem(
                            'All',
                            'All',
                            Icons.all_inclusive_rounded,
                          ),
                          _buildFilterMenuItem(
                            'Today',
                            'Today',
                            Icons.today_rounded,
                          ),
                          _buildFilterMenuItem(
                            'This Week',
                            'This Week',
                            Icons.date_range_rounded,
                          ),
                          _buildFilterMenuItem(
                            'This Month',
                            'This Month',
                            Icons.calendar_month_rounded,
                          ),
                          _buildFilterMenuItem(
                            'Custom',
                            'Custom',
                            Icons.tune_rounded,
                          ),
                        ],
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAF6EE),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5DEC9)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.filter_list_rounded,
                                size: 18,
                                color: Color(0xFF5E543F),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Filter: $_filterDisplayLabel',
                                style: GoogleFonts.montserrat(
                                  color: const Color(0xFF5E543F),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Print Button
                      GestureDetector(
                        onTap: () async {
                          try {
                            final pdfBytes = await PdfService.generateStatementPdf(
                              transactions: List.from(filtered)..sort((a, b) => a.date.compareTo(b.date)),
                              title: 'Statement',
                              subtitle: null,
                              periodText: 'PERIOD: ${_periodPrintLabel.toUpperCase()}',
                            );
                            await PdfService.printPdf(pdfBytes);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error printing: $e')));
                            }
                          }
                        },
                        child: Container(
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAF6EE),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5DEC9)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.print_rounded,
                                size: 18,
                                color: Color(0xFF735C0F),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Print',
                                style: GoogleFonts.montserrat(
                                  color: const Color(0xFF735C0F),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // Full-width search row with back button when search is active in portrait mode
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Color(0xFF01565B),
                    ),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                      });
                      _searchFocusNode.unfocus();
                    },
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAF6EE),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE5DEC9)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val;
                          });
                        },
                        style: GoogleFonts.montserrat(fontSize: 13),
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          hintText:
                              'Search by customer name, notes, or metal type',
                          hintStyle: GoogleFonts.montserrat(
                            color: const Color(0xFF5E543F).withOpacity(0.6),
                            fontSize: 13,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: Color(0xFF5E543F),
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    size: 16,
                                    color: Color(0xFF5E543F),
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                )
                              : null,
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Table Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            color: const Color(0xFFFAF6EE),
            child: Row(
              children: [
                Expanded(
                  flex: dateFlex,
                  child: Text(
                    'DATE',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 16 / 12,
                      letterSpacing: 12 * 0.08,
                      color: const Color(0xFF5E543F),
                    ),
                  ),
                ),
                Expanded(
                  flex: nameFlex,
                  child: Text(
                    'CUSTOMER NAME',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 16 / 12,
                      letterSpacing: 12 * 0.08,
                      color: const Color(0xFF5E543F),
                    ),
                  ),
                ),
                Expanded(
                  flex: categoryFlex,
                  child: Text(
                    'CATEGORY',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 16 / 12,
                      letterSpacing: 12 * 0.08,
                      color: const Color(0xFF5E543F),
                    ),
                  ),
                ),
                Expanded(
                  flex: amountFlex,
                  child: Text(
                    'VALUE',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 16 / 12,
                      letterSpacing: 12 * 0.08,
                      color: const Color(0xFF5E543F),
                    ),
                  ),
                ),
                Expanded(
                  flex: notesFlex,
                  child: Text(
                    'NOTES',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 16 / 12,
                      letterSpacing: 12 * 0.08,
                      color: const Color(0xFF5E543F),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Transaction Rows & Dynamic Calculations
          transactionsAsync.when(
            data: (transactions) {
              // Using pre-filtered transactions list from outer scope of _buildTabletHomeScreen
              if (filtered.isEmpty) {
                return Container(
                  height: 160,
                  alignment: Alignment.center,
                  child: Text(
                    transactions.isEmpty
                        ? 'No transactions recorded'
                        : 'No matching transactions found',
                    style: GoogleFonts.montserrat(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 20 / 14,
                      letterSpacing: 0,
                      color: const Color(0xFF5E543F).withOpacity(0.6),
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const Divider(
                      color: Color(0xFFE5DEC9),
                      height: 24,
                      thickness: 1.2,
                    ),
                    itemBuilder: (context, index) {
                      final t = filtered[index];
                      final isCredit =
                          t.type == TransactionType.receipt ||
                          t.type == TransactionType.metalIn;
                      final dateStr = DateFormat('dd MMM, yyyy').format(t.date);
                      final timeStr = DateFormat('hh:mm a').format(t.date);

                      // Customer Avatar color based on initials/name
                      final initial = t.partyName.isNotEmpty
                          ? t.partyName[0].toUpperCase()
                          : '?';
                      final avatarBgColor = _getAvatarColorForName(t.partyName);

                      // Category Pill using Transaction Type / Badge specs
                      Widget categoryPill;
                      if (t.metalType.isEmpty) {
                        if (t.paymentMode == PaymentMode.upi ||
                            t.paymentMode == PaymentMode.online) {
                          categoryPill = _buildCategoryPill(
                            'UPI',
                            const Color(0xFFE0F7FA),
                            const Color(0xFF00838F),
                          );
                        } else if (t.paymentMode == PaymentMode.rtgs) {
                          categoryPill = _buildCategoryPill(
                            'RTGS',
                            const Color(0xFFF3E5F5),
                            const Color(0xFF6A1B9A),
                          );
                        } else {
                          categoryPill = _buildCategoryPill(
                            'Cash',
                            const Color(0xFFE8F8F0),
                            const Color(0xFF00994C),
                          );
                        }
                      } else if (t.metalType == 'gold') {
                        categoryPill = _buildCategoryPill(
                          'Gold',
                          const Color(0xFFFFF9E6),
                          const Color(0xFFB38600),
                        );
                      } else {
                        categoryPill = _buildCategoryPill(
                          'Diamond',
                          const Color(0xFFE6F0FA),
                          const Color(0xFF0066CC),
                        );
                      }

                      // Amount
                      String amountStr = '';
                      final amountColor = isCredit
                          ? const Color(0xFF01565B)
                          : const Color(0xFFC62828);
                      final sign = isCredit ? '+ ' : '- ';

                      if (t.metalType.isEmpty) {
                        amountStr =
                            '$sign₹ ${NumberFormat.decimalPattern('en_IN').format(t.cashAmount)}';
                      } else if (t.metalType == 'gold') {
                        amountStr = '$sign${t.metalWeight} g';
                      } else {
                        amountStr = '$sign${t.metalWeight} ct';
                      }

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ), // Adjusted vertical padding to pair with new divider height
                        child: Row(
                          children: [
                            // DATE Column (Styled with Timestamp Spec)
                            Expanded(
                              flex: dateFlex,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    dateStr,
                                    style: GoogleFonts.montserrat(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      height: 16 / 12,
                                      letterSpacing: 12 * 0.01,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    timeStr,
                                    style: GoogleFonts.montserrat(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      height: 16 / 12,
                                      letterSpacing: 12 * 0.01,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // CUSTOMER NAME Column (Styled with Party Name Spec & Row Primary)
                            Expanded(
                              flex: nameFlex,
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: () {
                                      final parties = ref.read(partiesStreamProvider).value ?? [];
                                      final party = parties.firstWhere(
                                        (p) => p.id == t.partyId,
                                        orElse: () => PartyModel(
                                          id: t.partyId,
                                          name: t.partyName,
                                          type: 'Customer',
                                          phone: t.partyPhone,
                                          email: '',
                                          address: '',
                                          cashBalance: 0,
                                          goldBalanceGrams: 0,
                                          silverBalanceGrams: 0,
                                          diamondBalanceCarats: 0,
                                          openingCashBalance: 0,
                                          openingGoldBalanceGrams: 0,
                                          openingDiamondBalanceCarats: 0,
                                          createdAt: TimeUtils.now,
                                          updatedAt: TimeUtils.now,
                                        ),
                                      );
                                      
                                      showModalBottomSheet(
                                        context: context,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (context) => QuickPartyInfoSheet(
                                          party: party,
                                          transaction: t,
                                        ),
                                      );
                                    },
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: avatarBgColor,
                                        shape: BoxShape.circle,
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        initial,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          height: 20 / 14,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      t.partyName,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        height: 22 / 16,
                                        letterSpacing: 0,
                                        color: Colors.black87,
                                      ),
                                      maxLines: isPortrait ? null : 1,
                                      overflow: isPortrait
                                          ? null
                                          : TextOverflow.ellipsis,
                                      softWrap: true,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // CATEGORY Column
                            Expanded(
                              flex: categoryFlex,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: categoryPill,
                              ),
                            ),

                            // VALUE Column (Styled with Credit/Debit Amount Specs)
                            Expanded(
                              flex: amountFlex,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    amountStr,
                                    style: GoogleFonts.montserrat(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      height: 20 / 15,
                                      letterSpacing: 0,
                                      color: amountColor,
                                    ),
                                  ),
                                  if (t.metalType == 'gold' &&
                                      t.metalPurity.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFAF6EE),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: const Color(0xFFE5DEC9),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        t.metalPurity.endsWith('%') ||
                                                t.metalPurity.contains('Purity')
                                            ? t.metalPurity
                                            : '${t.metalPurity}% Purity',
                                        style: GoogleFonts.montserrat(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: const Color(0xFF735C0F),
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (t.metalType == 'diamond' &&
                                      t.metalPurity.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Builder(
                                      builder: (context) {
                                        String displayPieces = t.metalPurity;
                                        if (displayPieces.endsWith(' p')) {
                                          displayPieces = displayPieces
                                              .replaceAll(' p', ' Pcs');
                                        } else if (!displayPieces.contains(
                                              'Pcs',
                                            ) &&
                                            !displayPieces.contains('pcs') &&
                                            !displayPieces.contains('p')) {
                                          displayPieces = '$displayPieces Pcs';
                                        } else if (displayPieces.contains(
                                          'pcs',
                                        )) {
                                          displayPieces = displayPieces
                                              .replaceAll('pcs', 'Pcs');
                                        }
                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFAF6EE),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: const Color(0xFFE5DEC9),
                                              width: 0.8,
                                            ),
                                          ),
                                          child: Text(
                                            displayPieces,
                                            style: GoogleFonts.montserrat(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF735C0F),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),

                            // NOTES Column (Styled with Secondary Details Spec)
                            Expanded(
                              flex: notesFlex,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      t.notes != null &&
                                              t.notes!.trim().isNotEmpty
                                          ? t.notes!
                                          : '-',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w400,
                                        height: 18 / 13,
                                        letterSpacing: 0,
                                        color: Colors.black54,
                                      ),
                                      maxLines: isPortrait ? null : 1,
                                      overflow: isPortrait
                                          ? null
                                          : TextOverflow.ellipsis,
                                      softWrap: true,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () => _showPrintReceiptDialog(
                                      context,
                                      t,
                                      amountStr,
                                      t.typeLabel,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFAF6EE),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFE5DEC9),
                                          width: 1.0,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.print_rounded,
                                        size: 14,
                                        color: Color(0xFF735C0F),
                                      ),
                                    ),
                                  ),
                                  if (ref.watch(isStaffProvider)) ...[
                                    const SizedBox(width: 6),
                                    GestureDetector(
                                      onTap: () => _showChangeDateDialog(t),
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFAF6EE),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFE5DEC9),
                                            width: 1.0,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.edit_calendar_rounded,
                                          size: 14,
                                          color: Color(0xFF735C0F),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    GestureDetector(
                                      onTap: () => _showSetReminderDialog(t),
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFAF6EE),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFE5DEC9),
                                            width: 1.0,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.notifications_active_outlined,
                                          size: 14,
                                          color: Color(0xFF735C0F),
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (!ref.watch(isStaffProvider)) ...[
                                    const SizedBox(width: 6),
                                    GestureDetector(
                                      onTap: () =>
                                          _showEditTransactionDialog(t),
                                      child: Container(
                                        padding: const EdgeInsets.all(5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFAF6EE),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFE5DEC9),
                                            width: 0.5,
                                          ),
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
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  _buildLoadMoreButton(txState),
                ],
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error loading transactions'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryPill(String label, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: GoogleFonts.montserrat(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 18 / 13,
          letterSpacing: 13 * 0.02,
          color: textColor,
        ),
      ),
    );
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

  // ==========================================
  // MOBILE SCREEN LAYOUT (UNCHANGED CORE ELEMENTS)
  // ==========================================

  Widget _buildProfileHeader() {
    final profile = ref.watch(activeProfileProvider);
    final isStaff = ref.watch(isStaffProvider);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF8A7311), width: 1.5),
          ),
          child: UserAvatar(
            name: profile.name,
            gradientIndex: profile.gradientIndex,
            iconIndex: profile.iconIndex,
            size: 40,
            fontSize: 16,
            iconSize: 18,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            profile.name,
            style: GoogleFonts.montserrat(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF735C0F),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          onPressed: () => _showSetAppointmentDialog(context, isTablet: false),
          icon: const Icon(
            Icons.calendar_today_outlined,
            color: Color(0xFF4A3E1F),
            size: 26,
          ),
        ),
        if (!isStaff)
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      const DeviceManagementScreen(initialTabIndex: 1),
                ),
              );
            },
            icon: Badge(
              isLabelVisible: ref
                  .watch(userProfilesNotifierProvider)
                  .profiles
                  .where((p) {
                    final isPending =
                        p.status == 'pending_approval' ||
                        p.requestPending == true;
                    if (!isPending) return false;
                    final diff = DateTime.now().difference(
                      p.requestedAt ?? p.createdAt ?? DateTime.now(),
                    );
                    return diff.inMinutes < 5;
                  })
                  .isNotEmpty,
              label: Text(
                ref
                    .watch(userProfilesNotifierProvider)
                    .profiles
                    .where((p) {
                      final isPending =
                          p.status == 'pending_approval' ||
                          p.requestPending == true;
                      if (!isPending) return false;
                      final diff = DateTime.now().difference(
                        p.requestedAt ?? p.createdAt ?? DateTime.now(),
                      );
                      return diff.inMinutes < 5;
                    })
                    .length
                    .toString(),
              ),
              child: const Icon(
                Icons.notifications_none_outlined,
                color: Color(0xFF4A3E1F),
                size: 28,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBalancesGrid({
    required String cash,
    required String online,
    required String gold,
    required String diamond,
  }) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.7,
      children: [
        _buildGridCard(
          'Total Cash',
          cash,
          Icons.payments_outlined,
          const Color(0xFFE8F8F0),
          const Color(0xFF01565B),
          const Color(0xFF01565B),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  const TransactionStatementScreen(category: 'cash'),
            ),
          ),
        ),
        _buildGridCard(
          'Online Balance',
          online,
          Icons.account_balance_rounded,
          const Color(0xFFE6F0FA),
          const Color(0xFF2E5BFF),
          const Color(0xFF2E5BFF),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  const TransactionStatementScreen(category: 'online'),
            ),
          ),
        ),
        _buildGridCard(
          'Gold Balance',
          gold,
          Icons.widgets_rounded,
          const Color(0xFFFFF9E6),
          const Color(0xFF735C0F),
          const Color(0xFFDFBA6B),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  const TransactionStatementScreen(category: 'gold'),
            ),
          ),
        ),
        _buildGridCard(
          'Diamond Balance',
          diamond,
          Icons.diamond_rounded,
          const Color(0xFFE3EDF7),
          const Color(0xFF4F709C),
          const Color(0xFF8EACCD),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  const TransactionStatementScreen(category: 'diamond'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGridCard(
    String title,
    String value,
    IconData icon,
    Color iconBgColor,
    Color iconColor,
    Color accentColor, {
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFE5DEC9).withOpacity(0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Container(width: 4, color: accentColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: GoogleFonts.montserrat(
                              fontSize: 12,
                              color: const Color(0xFF5E543F).withOpacity(0.8),
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, color: iconColor, size: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            value,
                            style: GoogleFonts.montserrat(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: accentColor.withOpacity(0.3),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.chevron_right_rounded,
                            color: accentColor,
                            size: 14,
                          ),
                        ),
                      ],
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

  Widget _buildRecentTransactions() {
    final txState = ref.watch(homeTransactionsProvider);
    final transactionsAsync = _asAsync(txState);
    final transactions = transactionsAsync.value ?? [];

    // 1. Apply the shared date filter (trims the padded server window to the
    //    exact selected days; a no-op for the 'All' filter).
    final dateFilteredTransactions = _applyDateFilter(transactions);

    // 2. Apply search query filter
    final filteredTransactions = dateFilteredTransactions.where((t) {
      final query = _searchQuery.toLowerCase().trim();
      if (query.isEmpty) return true;
      return t.partyName.toLowerCase().contains(query) ||
          t.notes.toLowerCase().contains(query) ||
          t.metalType.toLowerCase().contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Transactions",
          style: GoogleFonts.montserrat(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF01565B),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE5DEC9)),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                  style: GoogleFonts.montserrat(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search transactions...',
                    hintStyle: GoogleFonts.montserrat(
                      color: const Color(0xFF5E543F).withOpacity(0.6),
                      fontSize: 13,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: Color(0xFF5E543F),
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear_rounded,
                              size: 16,
                              color: Color(0xFF5E543F),
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          )
                        : null,
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'Custom') {
                  _openCustomFilterSheet();
                } else {
                  setState(() {
                    _selectedTableFilter = value;
                    _customFilterResult = null;
                  });
                  _syncFilterToProvider();
                }
              },
              itemBuilder: (context) => [
                _buildFilterMenuItem('All', 'All', Icons.all_inclusive_rounded),
                _buildFilterMenuItem('Today', 'Today', Icons.today_rounded),
                _buildFilterMenuItem(
                  'This Week',
                  'This Week',
                  Icons.date_range_rounded,
                ),
                _buildFilterMenuItem(
                  'This Month',
                  'This Month',
                  Icons.calendar_month_rounded,
                ),
                _buildFilterMenuItem('Custom', 'Custom', Icons.tune_rounded),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF6EE),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE5DEC9)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.filter_list_rounded,
                      size: 16,
                      color: Color(0xFF5E543F),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _filterDisplayLabel,
                      style: GoogleFonts.montserrat(
                        color: const Color(0xFF5E543F),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () async {
                try {
                  final pdfBytes = await PdfService.generateStatementPdf(
                    transactions: List.from(filteredTransactions)..sort((a, b) => a.date.compareTo(b.date)),
                    title: 'Statement',
                    subtitle: null,
                    periodText: 'PERIOD: ${_periodPrintLabel.toUpperCase()}',
                  );
                  await PdfService.printPdf(pdfBytes);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error printing: $e')));
                  }
                }
              },
              child: Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFFAF6EE),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE5DEC9)),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.print_rounded,
                  size: 18,
                  color: Color(0xFF735C0F),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        transactionsAsync.when(
          data: (_) {
            if (filteredTransactions.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.withOpacity(0.1)),
                ),
                child: Center(
                  child: Text(
                    'No transactions for this period',
                    style: GoogleFonts.montserrat(color: Colors.grey),
                  ),
                ),
              );
            }

            return Column(
              children: filteredTransactions.map((activity) {
                final isCredit =
                    activity.type == TransactionType.receipt ||
                    activity.type == TransactionType.metalIn;
                final color = isCredit
                    ? const Color(0xFF2852C6)
                    : const Color(0xFFC62828);
                final typeLabel = isCredit ? 'In' : 'Out';

                String topRightLabel = '';
                String middleRightLabel = '';

                if (activity.metalType.isEmpty) {
                  topRightLabel = activity.paymentMode.name.toUpperCase();
                  middleRightLabel =
                      '₹ ${NumberFormat.decimalPattern('en_IN').format(activity.cashAmount)}';
                } else if (activity.metalType == 'gold') {
                  topRightLabel =
                      'Gold (${activity.metalPurity.endsWith('%') ? activity.metalPurity : '${activity.metalPurity}%'})';
                  middleRightLabel = '${activity.metalWeight}g';
                } else if (activity.metalType == 'diamond') {
                  topRightLabel = 'Diamond (${activity.metalWeight}ct)';
                  String displayPieces = activity.metalPurity;
                  if (displayPieces.endsWith(' p')) {
                    displayPieces = displayPieces.replaceAll(' p', ' Pcs');
                  } else if (!displayPieces.contains('Pcs') &&
                      !displayPieces.contains('pcs') &&
                      !displayPieces.contains('p') &&
                      displayPieces.isNotEmpty) {
                    displayPieces = '$displayPieces Pcs';
                  } else if (displayPieces.contains('pcs')) {
                    displayPieces = displayPieces.replaceAll('pcs', 'Pcs');
                  }
                  middleRightLabel = displayPieces;
                }

                final initial = activity.partyName.isNotEmpty
                    ? activity.partyName[0].toUpperCase()
                    : '?';
                final dateStr = DateFormat('dd MMM yyyy').format(activity.date);
                final timeStr = DateFormat('hh:mm a').format(activity.date);

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 4,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    final parties = ref.read(partiesStreamProvider).value ?? [];
                                    final party = parties.firstWhere(
                                      (p) => p.id == activity.partyId,
                                      orElse: () => PartyModel(
                                        id: activity.partyId,
                                        name: activity.partyName,
                                        type: 'Customer',
                                        phone: activity.partyPhone,
                                        email: '',
                                        address: '',
                                        cashBalance: 0,
                                        goldBalanceGrams: 0,
                                        silverBalanceGrams: 0,
                                        diamondBalanceCarats: 0,
                                        openingCashBalance: 0,
                                        openingGoldBalanceGrams: 0,
                                        openingDiamondBalanceCarats: 0,
                                        createdAt: TimeUtils.now,
                                        updatedAt: TimeUtils.now,
                                      ),
                                    );
                                    
                                    showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      backgroundColor: Colors.transparent,
                                      builder: (context) => QuickPartyInfoSheet(
                                        party: party,
                                        transaction: activity,
                                      ),
                                    );
                                  },
                                  child: Container(
                                    width: 48,
                                    height: 48,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF0EBE1),
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      initial,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF6B5800),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        activity.partyName,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.black,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        dateStr,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      Text(
                                        timeStr,
                                        style: GoogleFonts.montserrat(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      topRightLabel,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: color,
                                      ),
                                    ),
                                    Text(
                                      middleRightLabel,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: color,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          typeLabel,
                                          style: GoogleFonts.montserrat(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: color,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        GestureDetector(
                                          onTap: () => _showPrintReceiptDialog(
                                            context,
                                            activity,
                                            middleRightLabel,
                                            activity.typeLabel,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.all(5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFFAF6EE),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: const Color(0xFFE5DEC9),
                                                width: 0.5,
                                              ),
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
                                      onTap: () => _showChangeDateDialog(activity),
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFAF6EE),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xFFE5DEC9),
                                            width: 1.0,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.edit_calendar_rounded,
                                          size: 14,
                                          color: Color(0xFF735C0F),
                                        ),
                                      ),
                                    ),
                                          const SizedBox(width: 6),
                                          GestureDetector(
                                            onTap: () => _showSetReminderDialog(
                                              activity,
                                            ),
                                            child: Container(
                                              padding: const EdgeInsets.all(5),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFAF6EE),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFFE5DEC9,
                                                  ),
                                                  width: 0.5,
                                                ),
                                              ),
                                              child: const Icon(
                                                Icons
                                                    .notifications_active_outlined,
                                                size: 13,
                                                color: Color(0xFF735C0F),
                                              ),
                                            ),
                                          ),
                                        ],
                                        if (!ref.watch(isStaffProvider)) ...[
                                          const SizedBox(width: 6),
                                          GestureDetector(
                                            onTap: () =>
                                                _showEditTransactionDialog(
                                                  activity,
                                                ),
                                            child: Container(
                                              padding: const EdgeInsets.all(5),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFFAF6EE),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFFE5DEC9,
                                                  ),
                                                  width: 0.5,
                                                ),
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
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error loading transactions')),
        ),
        _buildLoadMoreButton(txState),
      ],
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
                    style: GoogleFonts.montserrat(
                      fontSize: 14,
                      color: Colors.black87,
                    ),
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
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          txn.metalType.isEmpty
                              ? '₹${txn.cashAmount.toStringAsFixed(2)}'
                              : '${txn.metalWeight} ${txn.metalType == 'gold' ? 'g' : 'ct'}',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color:
                                txn.type == TransactionType.receipt ||
                                    txn.type == TransactionType.metalIn
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
                          setDialogState(() => isDeleting = true);
                          final success = await ref
                              .read(transactionNotifierProvider.notifier)
                              .deleteTransaction(txn);
                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? 'Transaction deleted successfully'
                                      : 'Failed to delete transaction',
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.w600,
                                  ),
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
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: isDeleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : Text(
                          'Delete',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
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
      text: txn.metalType.isEmpty
          ? txn.cashAmount.toString()
          : txn.metalWeight.toString(),
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
    PaymentMode selectedPaymentMode = txn.paymentMode == PaymentMode.online
        ? PaymentMode.upi
        : txn.paymentMode;

    showDialog(
      context: context,
      builder: (context) {
        bool isSaving = false;
        bool isIn =
            txn.type == TransactionType.receipt ||
            txn.type == TransactionType.metalIn;

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
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFFDFBA6B),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: const Color(0xFFDFBA6B).withOpacity(0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF6B5800),
                            width: 1.5,
                          ),
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
                              Icon(
                                Icons.arrow_downward_rounded,
                                color: Color(0xFF2E7D32),
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'In',
                                style: TextStyle(
                                  color: Color(0xFF2E7D32),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        DropdownMenuItem<bool>(
                          value: false,
                          child: Row(
                            children: [
                              Icon(
                                Icons.arrow_upward_rounded,
                                color: Color(0xFFC62828),
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Out',
                                style: TextStyle(
                                  color: Color(0xFFC62828),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFDFBA6B),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                              color: const Color(0xFFDFBA6B).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFF6B5800),
                              width: 1.5,
                            ),
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
                      style: GoogleFonts.montserrat(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Add description...',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFFDFBA6B),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: const Color(0xFFDFBA6B).withOpacity(0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF6B5800),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFDFBA6B).withOpacity(0.5),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        title: Text(
                          'Date & Time',
                          style: GoogleFonts.montserrat(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey[600],
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            DateFormat(
                              'dd MMM yyyy • hh:mm a',
                            ).format(selectedDate),
                            style: GoogleFonts.montserrat(
                              fontSize: 12,
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
                            firstDate: selectedDate.subtract(
                              const Duration(days: 365),
                            ),
                            lastDate: DateTime.now().add(
                              const Duration(days: 1),
                            ),
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
                                    side: const BorderSide(
                                      color: Color(0xFFDFBA6B),
                                      width: 1.5,
                                    ),
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
                                    style: GoogleFonts.montserrat(
                                      fontSize: 14,
                                      color: Colors.black87,
                                    ),
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
                                              setConfirmState(
                                                () => isDeleting = true,
                                              );
                                              final success = await ref
                                                  .read(
                                                    transactionNotifierProvider
                                                        .notifier,
                                                  )
                                                  .deleteTransaction(txn);
                                              if (mounted) {
                                                Navigator.pop(confirmContext);
                                                Navigator.pop(context);
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      success
                                                          ? 'Transaction deleted successfully'
                                                          : 'Failed to delete transaction',
                                                      style:
                                                          GoogleFonts.montserrat(
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                    ),
                                                    backgroundColor: success
                                                        ? const Color(
                                                            0xFF2E7D32,
                                                          )
                                                        : const Color(
                                                            0xFFC62828,
                                                          ),
                                                  ),
                                                );
                                              }
                                            },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFFC62828,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      child: isDeleting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(Colors.white),
                                              ),
                                            )
                                          : Text(
                                              'Delete',
                                              style: GoogleFonts.montserrat(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
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
                          onPressed: isSaving
                              ? null
                              : () => Navigator.pop(context),
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
                          onPressed: isSaving
                              ? null
                              : () async {
                                  final val =
                                      double.tryParse(amountController.text) ??
                                      0.0;
                                  if (val <= 0) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Please enter a valid amount or weight',
                                        ),
                                      ),
                                    );
                                    return;
                                  }

                                  setDialogState(() => isSaving = true);

                                  final isMetal = txn.metalType.isNotEmpty;
                                  final TransactionType finalType = isMetal
                                      ? (isIn
                                            ? TransactionType.metalIn
                                            : TransactionType.metalOut)
                                      : (isIn
                                            ? TransactionType.receipt
                                            : TransactionType.payment);

                                  String finalPurity = txn.metalPurity;
                                  if (txn.metalType == 'gold') {
                                    finalPurity = purityController.text.trim();
                                  } else if (txn.metalType == 'diamond') {
                                    finalPurity =
                                        '${piecesController.text.trim()} p';
                                  }

                                  final newTx = TransactionModel(
                                    id: txn.id,
                                    partyId: txn.partyId,
                                    partyName: txn.partyName,
                                    partyPhone: txn.partyPhone,
                                    type: finalType,
                                    paymentMode: txn.metalType.isEmpty
                                        ? selectedPaymentMode
                                        : txn.paymentMode,
                                    cashAmount: txn.metalType.isEmpty
                                        ? val
                                        : txn.cashAmount,
                                    metalType: txn.metalType,
                                    metalWeight: txn.metalType.isNotEmpty
                                        ? val
                                        : txn.metalWeight,
                                    metalPurity: finalPurity,
                                    notes: notesController.text,
                                    date: selectedDate,
                                    createdAt: txn.createdAt,
                                  );

                                  final success = await ref
                                      .read(
                                        transactionNotifierProvider.notifier,
                                      )
                                      .updateTransaction(
                                        oldTx: txn,
                                        newTx: newTx,
                                      );

                                  if (mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          success
                                              ? 'Transaction updated successfully'
                                              : 'Failed to update transaction',
                                          style: GoogleFonts.montserrat(
                                            fontWeight: FontWeight.w600,
                                          ),
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
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : Text(
                                  'Save',
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
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

  void _showSetAppointmentDialog(
    BuildContext context, {
    required bool isTablet,
  }) {
    final customerNameController = TextEditingController();
    final phoneController = TextEditingController();
    final notesController = TextEditingController();
    final customerNameFocusNode = FocusNode();

    DateTime selectedDate = DateTime.now().add(const Duration(days: 1));
    TimeOfDay selectedTime = const TimeOfDay(
      hour: 14,
      minute: 30,
    ); // 02:30 PM default
    bool remindBefore = false;
    bool showAutocomplete = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final partiesAsync = ref.watch(partiesStreamProvider);
            final parties = partiesAsync.value ?? [];
            final formattedDate = DateFormat(
              'MM / dd / yy',
            ).format(selectedDate);
            final formattedTime = DateFormat('hh : mm a').format(
              DateTime(2026, 1, 1, selectedTime.hour, selectedTime.minute),
            );

            return Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Container(
                width: isTablet ? 450 : double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header with Close Cross
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const SizedBox(width: 24),
                          Text(
                            'Set Appointment',
                            style: GoogleFonts.montserrat(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF735C0F),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: const Icon(
                              Icons.close,
                              color: Colors.black54,
                              size: 24,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Customer Name Field Header with + New Customer button
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Customer Name',
                            style: GoogleFonts.montserrat(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[700],
                            ),
                          ),
                          GestureDetector(
                            onTap: () async {
                              final newPartyId =
                                  await showModalBottomSheet<String>(
                                    context: context,
                                    isScrollControlled: true,
                                    backgroundColor: Colors.transparent,
                                    builder: (context) =>
                                        const QuickAddPartyBottomSheet(),
                                  );
                              if (newPartyId != null) {
                                // Wait a split second for stream to sync, then look it up or auto-fill
                                final updatedParties =
                                    ref.read(partiesStreamProvider).value ?? [];
                                final matches = updatedParties.where(
                                  (p) => p.id == newPartyId,
                                );
                                final newParty = matches.isNotEmpty
                                    ? matches.first
                                    : null;
                                if (newParty != null) {
                                  setDialogState(() {
                                    customerNameController.text = newParty.name;
                                    phoneController.text = newParty.phone;
                                    showAutocomplete = false;
                                  });
                                } else {
                                  // Fallback: search by ID in a delayed manner or check if we get updates
                                  Future.delayed(
                                    const Duration(milliseconds: 500),
                                    () {
                                      final partiesList = ref
                                          .read(partiesStreamProvider)
                                          .value;
                                      final delayedMatches = partiesList?.where(
                                        (p) => p.id == newPartyId,
                                      );
                                      final delayedParty =
                                          delayedMatches != null &&
                                              delayedMatches.isNotEmpty
                                          ? delayedMatches.first
                                          : null;
                                      if (delayedParty != null) {
                                        setDialogState(() {
                                          customerNameController.text =
                                              delayedParty.name;
                                          phoneController.text =
                                              delayedParty.phone;
                                          showAutocomplete = false;
                                        });
                                      }
                                    },
                                  );
                                }
                              }
                            },
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.add,
                                  color: Color(0xFF735C0F),
                                  size: 16,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'New Customer',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF735C0F),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: customerNameController,
                        focusNode: customerNameFocusNode,
                        style: GoogleFonts.montserrat(fontSize: 14),
                        onChanged: (value) {
                          setDialogState(() {
                            showAutocomplete = true;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Search or enter customer...',
                          hintStyle: GoogleFonts.montserrat(
                            color: Colors.grey[400],
                          ),
                          prefixIcon: const Icon(
                            Icons.person_outline,
                            color: Color(0xFF8A7311),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.8),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.8),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF8A7311),
                              width: 1.5,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),

                      // Autocomplete Overlay
                      if (showAutocomplete)
                        Builder(
                          builder: (context) {
                            final query = customerNameController.text
                                .toLowerCase()
                                .trim();
                            final matchingParties = query.isEmpty
                                ? []
                                : parties
                                      .where(
                                        (p) =>
                                            p.name.toLowerCase().contains(
                                              query,
                                            ) ||
                                            p.phone.contains(query),
                                      )
                                      .toList();

                            if (matchingParties.isEmpty)
                              return const SizedBox.shrink();

                            return Container(
                              margin: const EdgeInsets.only(top: 4),
                              constraints: const BoxConstraints(maxHeight: 180),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFE5DEC9),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: ListView.separated(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                itemCount: matchingParties.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(
                                      height: 1,
                                      color: Color(0xFFFAF6EE),
                                    ),
                                itemBuilder: (context, index) {
                                  final party = matchingParties[index];
                                  return ListTile(
                                    dense: true,
                                    leading: const CircleAvatar(
                                      backgroundColor: Color(0xFFFAF6EE),
                                      child: Icon(
                                        Icons.person,
                                        color: Color(0xFF735C0F),
                                        size: 16,
                                      ),
                                    ),
                                    title: Text(
                                      party.name,
                                      style: GoogleFonts.montserrat(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    subtitle: Text(
                                      party.phone.isNotEmpty
                                          ? party.phone
                                          : 'No phone saved',
                                      style: GoogleFonts.montserrat(
                                        fontSize: 12,
                                        color: Colors.grey[500],
                                      ),
                                    ),
                                    onTap: () {
                                      setDialogState(() {
                                        customerNameController.text =
                                            party.name;
                                        phoneController.text = party.phone;
                                        showAutocomplete = false;
                                      });
                                      customerNameFocusNode.unfocus();
                                    },
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 16),

                      // Phone Number Field (Read-only display!)
                      Text(
                        'Phone Number',
                        style: GoogleFonts.montserrat(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: phoneController,
                        readOnly:
                            true, // Read-only, auto-filled from selection!
                        style: GoogleFonts.montserrat(
                          fontSize: 14,
                          color: Colors.black87,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Auto-populated phone number',
                          hintStyle: GoogleFonts.montserrat(
                            color: Colors.grey[400],
                          ),
                          prefixIcon: const Icon(
                            Icons.phone_outlined,
                            color: Color(0xFF8A7311),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFFAF6EE).withOpacity(0.4),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.5),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.5),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Date & Time Picker Row
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Date',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[700],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final date = await showDatePicker(
                                      context: context,
                                      initialDate: selectedDate,
                                      firstDate: DateTime.now(),
                                      lastDate: DateTime.now().add(
                                        const Duration(days: 365),
                                      ),
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme:
                                                const ColorScheme.light(
                                                  primary: Color(0xFF735C0F),
                                                  onPrimary: Colors.white,
                                                  onSurface: Colors.black,
                                                ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (date != null) {
                                      setDialogState(() {
                                        selectedDate = date;
                                      });
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: const Color(
                                          0xFFE5DEC9,
                                        ).withOpacity(0.8),
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.calendar_today_outlined,
                                          color: Color(0xFF8A7311),
                                          size: 20,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            formattedDate,
                                            style: GoogleFonts.montserrat(
                                              fontSize: 14,
                                              color: Colors.black87,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Time',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[700],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final time = await showTimePicker(
                                      context: context,
                                      initialTime: selectedTime,
                                      builder: (context, child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme:
                                                const ColorScheme.light(
                                                  primary: Color(0xFF735C0F),
                                                  onPrimary: Colors.white,
                                                  onSurface: Colors.black,
                                                ),
                                          ),
                                          child: child!,
                                        );
                                      },
                                    );
                                    if (time != null) {
                                      setDialogState(() {
                                        selectedTime = time;
                                      });
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: const Color(
                                          0xFFE5DEC9,
                                        ).withOpacity(0.8),
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.access_time_outlined,
                                          color: Color(0xFF8A7311),
                                          size: 20,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            formattedTime,
                                            style: GoogleFonts.montserrat(
                                              fontSize: 14,
                                              color: Colors.black87,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Appointment Notes Field
                      Text(
                        'Appointment Notes',
                        style: GoogleFonts.montserrat(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: notesController,
                        textCapitalization: TextCapitalization.characters,
                        maxLines: 3,
                        style: GoogleFonts.montserrat(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Coming to pick up custom gold chain',
                          hintStyle: GoogleFonts.montserrat(
                            color: Colors.grey[400],
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.8),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: const Color(0xFFE5DEC9).withOpacity(0.8),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF8A7311),
                              width: 1.5,
                            ),
                          ),
                          contentPadding: const EdgeInsets.all(16),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Custom Switch Toggle
                      Row(
                        children: [
                          const Icon(
                            Icons.notifications_active_outlined,
                            color: Color(0xFF735C0F),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Remind me 1 day before',
                              style: GoogleFonts.montserrat(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          Switch(
                            value: remindBefore,
                            activeColor: const Color(0xFF735C0F),
                            activeTrackColor: const Color(
                              0xFF735C0F,
                            ).withOpacity(0.2),
                            inactiveThumbColor: Colors.grey[400],
                            inactiveTrackColor: Colors.grey[200],
                            onChanged: (val) {
                              setDialogState(() {
                                remindBefore = val;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Set Appointment Button
                      ElevatedButton(
                        onPressed: () async {
                          if (customerNameController.text.trim().isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Please enter a Customer Name'),
                              ),
                            );
                            return;
                          }

                          final dateVal = DateTime(
                            selectedDate.year,
                            selectedDate.month,
                            selectedDate.day,
                            selectedTime.hour,
                            selectedTime.minute,
                          );

                          await ref
                              .read(appointmentNotifierProvider.notifier)
                              .createAppointment(
                                customerName: customerNameController.text
                                    .trim(),
                                phoneNumber: phoneController.text.trim(),
                                date: dateVal,
                                notes: notesController.text.trim(),
                                remindBefore: remindBefore,
                              );

                          final appointmentState = ref.read(
                            appointmentNotifierProvider,
                          );
                          if (appointmentState.hasError) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Could not set appointment: ${appointmentState.error}',
                                ),
                              ),
                            );
                            return;
                          }

                          if (context.mounted) {
                            Navigator.pop(context);
                            ref.read(navigationProvider.notifier).setIndex(3);
                            ref
                                .read(reminderNavigationProvider.notifier)
                                .showAppointments(filter: 'All');
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Appointment set successfully'),
                              ),
                            );
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF735C0F),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          elevation: 0,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.calendar_today_outlined,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Set Appointment',
                              style: GoogleFonts.montserrat(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Cancel Text Button
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.montserrat(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSetReminderDialog(TransactionModel activity) {
    final msgController = TextEditingController();

    // Set a nice default message
    String defaultMsg = 'Follow up with ${activity.partyName}';
    if (activity.metalType.isEmpty) {
      defaultMsg +=
          ' for ₹${NumberFormat.decimalPattern('en_IN').format(activity.cashAmount)}';
    } else {
      defaultMsg +=
          ' for ${activity.metalWeight}${activity.metalType == 'gold' ? 'g' : 'ct'} ${activity.metalType}';
    }

    showDialog(
      context: context,
      builder: (context) {
        bool isSaving = false;
        String selectedTimeOption = 'Tomorrow';
        DateTime? customDate;
        TimeOfDay? customTime = const TimeOfDay(hour: 11, minute: 30);

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFAF6EE),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFFDFBA6B), width: 1.5),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Set Reminder',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF4A3E1F),
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Customer: ${activity.partyName}',
                    style: GoogleFonts.montserrat(
                      fontSize: 12,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'REMINDER MESSAGE',
                      style: GoogleFonts.montserrat(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[600],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: msgController,
                      maxLines: 2,
                      style: GoogleFonts.montserrat(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        hintText: defaultMsg,
                        hintStyle: GoogleFonts.montserrat(
                          fontSize: 13,
                          color: Colors.grey[400],
                          fontWeight: FontWeight.w400,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFFDFBA6B),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: const Color(0xFFDFBA6B).withOpacity(0.5),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: Color(0xFF6B5800),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'WHEN',
                      style: GoogleFonts.montserrat(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[600],
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children:
                          [
                            'Tomorrow',
                            'In 2 days',
                            'Next Week',
                            'Custom Date',
                          ].map((time) {
                            final isSelected = selectedTimeOption == time;
                            return GestureDetector(
                              onTap: () => setDialogState(
                                () => selectedTimeOption = time,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF6B5800)
                                      : const Color(0xFFFAF6EE),
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF6B5800)
                                        : const Color(0xFFE5DEC9),
                                    width: 1.0,
                                  ),
                                ),
                                child: Text(
                                  time,
                                  style: GoogleFonts.montserrat(
                                    fontSize: 11,
                                    fontWeight: isSelected
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? Colors.white
                                        : const Color(0xFF735C0F),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                    ),
                    if (selectedTimeOption == 'Custom Date') ...[
                      const SizedBox(height: 16),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFFDFBA6B).withOpacity(0.5),
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          title: Text(
                            'Schedule for',
                            style: GoogleFonts.montserrat(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[600],
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              (customDate != null && customTime != null)
                                  ? DateFormat('dd MMM yyyy • hh:mm a').format(
                                      DateTime(
                                        customDate!.year,
                                        customDate!.month,
                                        customDate!.day,
                                        customTime!.hour,
                                        customTime!.minute,
                                      ),
                                    )
                                  : 'Select Custom Date & Time',
                              style: GoogleFonts.montserrat(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color:
                                    (customDate != null && customTime != null)
                                    ? Colors.black87
                                    : Colors.grey[500],
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
                              initialDate:
                                  customDate ??
                                  TimeUtils.now.add(const Duration(days: 1)),
                              firstDate: TimeUtils.now,
                              lastDate: TimeUtils.now.add(
                                const Duration(days: 365),
                              ),
                              builder: (context, child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: const ColorScheme.light(
                                      primary: Color(
                                        0xFF6B5800,
                                      ), // header background color
                                      onPrimary:
                                          Colors.white, // header text color
                                      onSurface: Color(
                                        0xFF4A3E1F,
                                      ), // body text color
                                    ),
                                    textButtonTheme: TextButtonThemeData(
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(
                                          0xFF6B5800,
                                        ), // button text color
                                      ),
                                    ),
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            if (date != null) {
                              if (!mounted) return;
                              final time = await showTimePicker(
                                context: context,
                                initialTime:
                                    customTime ??
                                    const TimeOfDay(hour: 11, minute: 30),
                                builder: (context, child) {
                                  return Theme(
                                    data: Theme.of(context).copyWith(
                                      colorScheme: const ColorScheme.light(
                                        primary: Color(
                                          0xFF6B5800,
                                        ), // clock selection color
                                        onPrimary: Colors.white,
                                        onSurface: Color(0xFF4A3E1F),
                                      ),
                                      textButtonTheme: TextButtonThemeData(
                                        style: TextButton.styleFrom(
                                          foregroundColor: const Color(
                                            0xFF6B5800,
                                          ),
                                        ),
                                      ),
                                    ),
                                    child: MediaQuery(
                                      data: MediaQuery.of(
                                        context,
                                      ).copyWith(alwaysUse24HourFormat: false),
                                      child: child!,
                                    ),
                                  );
                                },
                              );
                              if (time != null) {
                                setDialogState(() {
                                  customDate = date;
                                  customTime = time;
                                });
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
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
                ElevatedButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          final noteText = msgController.text.trim().isEmpty
                              ? defaultMsg
                              : msgController.text.trim();

                          DateTime finalReminderDate;
                          if (selectedTimeOption == 'Tomorrow') {
                            final baseDate = TimeUtils.now.add(
                              const Duration(days: 1),
                            );
                            finalReminderDate = DateTime(
                              baseDate.year,
                              baseDate.month,
                              baseDate.day,
                              11,
                              30,
                            );
                          } else if (selectedTimeOption == 'In 2 days') {
                            final baseDate = TimeUtils.now.add(
                              const Duration(days: 2),
                            );
                            finalReminderDate = DateTime(
                              baseDate.year,
                              baseDate.month,
                              baseDate.day,
                              11,
                              30,
                            );
                          } else if (selectedTimeOption == 'Next Week') {
                            final baseDate = TimeUtils.now.add(
                              const Duration(days: 7),
                            );
                            finalReminderDate = DateTime(
                              baseDate.year,
                              baseDate.month,
                              baseDate.day,
                              11,
                              30,
                            );
                          } else {
                            if (customDate == null || customTime == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please select custom date and time',
                                  ),
                                ),
                              );
                              return;
                            }
                            finalReminderDate = DateTime(
                              customDate!.year,
                              customDate!.month,
                              customDate!.day,
                              customTime!.hour,
                              customTime!.minute,
                            );
                          }

                          setDialogState(() => isSaving = true);

                          await ref
                              .read(reminderNotifierProvider.notifier)
                              .createReminder(
                                partyId: activity.partyId,
                                partyName: activity.partyName,
                                partyPhone: activity.partyPhone,
                                title: 'Reminder',
                                note: noteText,
                                date: finalReminderDate,
                              );

                          if (mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Reminder set successfully',
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                backgroundColor: const Color(0xFF2E7D32),
                              ),
                            );
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A3E1F),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : Text(
                          'Set Reminder',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
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
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPrintReceiptDialog(
    BuildContext context,
    TransactionModel t,
    String amountStr,
    String badgeText,
  ) {
    final isCredit =
        t.type == TransactionType.receipt || t.type == TransactionType.metalIn;
    final dateStr = DateFormat('dd MMM yyyy').format(t.date);
    final timeStr = DateFormat('hh:mm a').format(t.date);

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
                  border: Border.all(
                    color: const Color(0xFFDFBA6B),
                    width: 1.5,
                  ),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
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
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 20,
                            ),
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
                            const CircularProgressIndicator(
                              color: Color(0xFF01565B),
                            ),
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
                            border: Border.all(
                              color: Colors.grey.withOpacity(0.2),
                            ),
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
                              _buildReceiptRow('Date:', '$dateStr  $timeStr'),
                              _buildReceiptRow('Customer Name:', t.partyName),
                              _buildReceiptRow(
                                'Type:',
                                isCredit ? 'IN' : 'OUT',
                              ),
                              _buildReceiptRow(
                                'Category:',
                                t.metalType.isEmpty
                                    ? 'Money'
                                    : t.metalType.toUpperCase(),
                              ),
                              if (badgeText.isNotEmpty)
                                _buildReceiptRow('Particulars:', badgeText),

                              Text(
                                '------------------------------------------',
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                              const SizedBox(height: 8),

                              // Amount / Details Highlight
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                  horizontal: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFAF6EE),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(0xFFE5DEC9),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
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
                                        color: isCredit
                                            ? const Color(0xFF01565B)
                                            : const Color(0xFFC62828),
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
                                    Icon(
                                      Icons.bar_chart_rounded,
                                      size: 40,
                                      color: Colors.grey[600],
                                    ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  setDialogState(() {
                                    isPrinting = true;
                                  });
                                  try {
                                    final pdfBytes =
                                        await PdfService.generateReceiptPdf(
                                          transaction: t,
                                          amountStr: amountStr,
                                          badgeText: badgeText,
                                        );
                                    await PdfService.printPdf(pdfBytes);
                                    if (context.mounted) Navigator.pop(context);
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Error printing: $e'),
                                        ),
                                      );
                                    }
                                    setDialogState(() {
                                      isPrinting = false;
                                    });
                                  }
                                },
                                icon: const Icon(
                                  Icons.print_rounded,
                                  size: 18,
                                  color: Color(0xFF01565B),
                                ),
                                label: Text(
                                  'Print',
                                  style: GoogleFonts.montserrat(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF01565B),
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                    color: Color(0xFF01565B),
                                    width: 1.5,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
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
                                    final pdfBytes =
                                        await PdfService.generateReceiptPdf(
                                          transaction: t,
                                          amountStr: amountStr,
                                          badgeText: badgeText,
                                        );
                                    final success =
                                        await PdfService.savePdfToDownloads(
                                          pdfBytes,
                                          'Receipt_${t.partyName.replaceAll(' ', '_')}_${DateFormat('ddMMMyyyy').format(t.date)}',
                                        );
                                    setDialogState(() {
                                      isPrinting = false;
                                      isSaved = success;
                                    });
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Error saving PDF: $e'),
                                        ),
                                      );
                                    }
                                    setDialogState(() {
                                      isPrinting = false;
                                    });
                                  }
                                },
                                icon: const Icon(
                                  Icons.picture_as_pdf,
                                  size: 18,
                                  color: Colors.white,
                                ),
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
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
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
}

// ==========================================
// TABLET QUICK ADD DIALOG & FORMATTERS
// ==========================================

class TabletQuickAddEntryDialog extends ConsumerStatefulWidget {
  const TabletQuickAddEntryDialog({super.key});

  @override
  ConsumerState<TabletQuickAddEntryDialog> createState() =>
      _TabletQuickAddEntryDialogState();
}

class _TabletQuickAddEntryDialogState
    extends ConsumerState<TabletQuickAddEntryDialog> {
  String _transactionType = 'IN';
  String _category = 'Money'; // Money, Gold, Diamond
  String _paymentMode = 'Cash'; // Cash, UPI, RTGS
  DateTime _selectedDate = TimeUtils.now;
  TimeOfDay _selectedTime = TimeOfDay.now();
  Timer? _clockTimer;
  bool _isTimeManuallySet = false;

  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _partyController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _purityController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _caratController = TextEditingController();
  final TextEditingController _piecesController = TextEditingController();
  final FocusNode _partyFocusNode = FocusNode();

  PartyModel? _selectedParty;
  String? _pendingPartyId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _selectedTime = TimeOfDay.now();
          if (!_isTimeManuallySet) {
            _selectedDate = TimeUtils.now;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _amountController.dispose();
    _partyController.dispose();
    _notesController.dispose();
    _purityController.dispose();
    _weightController.dispose();
    _caratController.dispose();
    _piecesController.dispose();
    _partyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parties = ref.watch(partiesStreamProvider).value ?? [];
    final isStaff = ref.watch(isStaffProvider);

    if (_pendingPartyId != null && parties.isNotEmpty) {
      try {
        final party = parties.firstWhere((p) => p.id == _pendingPartyId);
        _pendingPartyId = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _selectedParty = party;
              _partyController.text = party.name;
            });
          }
        });
      } catch (_) {}
    }

    return Container(
      width: 620,
      constraints: const BoxConstraints(maxHeight: 750),
      decoration: BoxDecoration(
        color: const Color(
          0xFFFAF6EE,
        ), // Sleek warm beige background matching the screenshot
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE5DEC9), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(28.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header Row: Title & Pickers
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quick Add Entry',
                      style: GoogleFonts.montserrat(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF01565B), // Deep teal
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Record transaction details.',
                      style: GoogleFonts.montserrat(
                        fontSize: 13,
                        color: const Color(0xFF5E543F).withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    _buildDateTimePicker(
                      icon: Icons.calendar_today_outlined,
                      text: DateFormat('dd MMM yyyy').format(_selectedDate),
                      showArrow: true,
                      onTap: () async {
                        final DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDate,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() {
                            _selectedDate = picked;
                            _isTimeManuallySet = true;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _buildDateTimePicker(
                      icon: Icons.access_time_outlined,
                      text: _selectedTime.format(context),
                      onTap: null,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            // IN / OUT Toggle
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF4EDE4),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: _buildTransactionTypeButton(
                      title: 'IN (Receive)',
                      icon: Icons.arrow_downward,
                      selectedColor: const Color(0xFF01565B),
                      isSelected: _transactionType == 'IN',
                      onTap: () => setState(() => _transactionType = 'IN'),
                    ),
                  ),
                  Expanded(
                    child: _buildTransactionTypeButton(
                      title: 'OUT (Give)',
                      icon: Icons.arrow_upward,
                      selectedColor: const Color(0xFFC62828),
                      isSelected: _transactionType == 'OUT',
                      onTap: () => setState(() => _transactionType = 'OUT'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Party / Customer Selector Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Party / Customer',
                  style: GoogleFonts.montserrat(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF5E543F),
                  ),
                ),
                InkWell(
                  onTap: () async {
                    final newId = await showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) => const QuickAddPartyBottomSheet(),
                    );
                    if (newId != null && newId is String) {
                      final list = ref.read(partiesStreamProvider).value ?? [];
                      final found = list
                          .where((p) => p.id == newId)
                          .firstOrNull;
                      if (found != null) {
                        setState(() {
                          _selectedParty = found;
                          _partyController.text = found.name;
                          _pendingPartyId = null;
                        });
                      } else {
                        setState(() => _pendingPartyId = newId);
                      }
                    }
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFDFBA6B)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.add,
                          size: 16,
                          color: Color(0xFF735C0F),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Add New',
                          style: GoogleFonts.montserrat(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF735C0F),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildPartyAutocomplete(),
            const SizedBox(height: 20),

            // Category Toggle
            Text(
              'Category',
              style: GoogleFonts.montserrat(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF5E543F),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF4EDE4),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  _buildCategoryButton('Money'),
                  _buildCategoryButton('Gold'),
                  _buildCategoryButton('Diamond'),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Dynamic Form Fields based on Category
            if (_category == 'Money') ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFE5DEC9).withOpacity(0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Payment Mode',
                      style: GoogleFonts.montserrat(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF5E543F),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildPaymentModeChip('Cash'),
                        const SizedBox(width: 12),
                        _buildPaymentModeChip('UPI'),
                        const SizedBox(width: 12),
                        _buildPaymentModeChip('RTGS'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Amount',
                      style: GoogleFonts.montserrat(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF5E543F),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _amountController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        _IndianCurrencyFormatter(),
                      ],
                      style: GoogleFonts.montserrat(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: InputDecoration(
                        hintText: '0',
                        hintStyle: GoogleFonts.montserrat(
                          color: Colors.grey.shade300,
                          fontSize: 18,
                        ),
                        prefixIcon: Padding(
                          padding: const EdgeInsets.all(6.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4EDE4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '₹',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF735C0F),
                              ),
                            ),
                          ),
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 0,
                          minHeight: 0,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade400),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade400),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFDFBA6B),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (_category == 'Gold') ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Purity %',
                          style: GoogleFonts.montserrat(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF5E543F),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _purityController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textAlign: TextAlign.right,
                          style: GoogleFonts.montserrat(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: '99.5',
                            hintStyle: GoogleFonts.montserrat(
                              color: Colors.grey.shade400,
                              fontSize: 15,
                            ),
                            suffixIcon: Padding(
                              padding: const EdgeInsets.only(right: 12.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '%',
                                    style: GoogleFonts.montserrat(
                                      fontSize: 16,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 0,
                              minHeight: 0,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFDFBA6B),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Weight (g)',
                          style: GoogleFonts.montserrat(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF5E543F),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _weightController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textAlign: TextAlign.right,
                          style: GoogleFonts.montserrat(fontSize: 15),
                          decoration: InputDecoration(
                            hintText: '0.00',
                            hintStyle: GoogleFonts.montserrat(
                              color: Colors.grey.shade400,
                              fontSize: 15,
                            ),
                            suffixIcon: Padding(
                              padding: const EdgeInsets.only(right: 12.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'g',
                                    style: GoogleFonts.montserrat(
                                      fontSize: 16,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 0,
                              minHeight: 0,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFDFBA6B),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ] else if (_category == 'Diamond') ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CARAT (CT)',
                          style: GoogleFonts.montserrat(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF5E543F),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _caratController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.montserrat(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: '0.00',
                            hintStyle: GoogleFonts.montserrat(
                              color: Colors.grey.shade400,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFDFBA6B),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PIECES',
                          style: GoogleFonts.montserrat(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF5E543F),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _piecesController,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.montserrat(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: '0',
                            hintStyle: GoogleFonts.montserrat(
                              color: Colors.grey.shade400,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFDFBA6B),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),

            // Particulars / Notes
            Text(
              'Particulars / Notes',
              style: GoogleFonts.montserrat(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF5E543F),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              textCapitalization: TextCapitalization.characters,
              maxLines: 2,
              style: GoogleFonts.montserrat(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Add details about the transaction...',
                hintStyle: GoogleFonts.montserrat(color: Colors.grey.shade500),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFFF4EDE4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.montserrat(
                        color: Colors.black87,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveTransaction,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: const Color(0xFFDFBA6B), // Gold
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFF01565B),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.check,
                                color: Color(0xFF01565B),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Save Entry',
                                style: GoogleFonts.montserrat(
                                  color: const Color(0xFF01565B),
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateTimePicker({
    required IconData icon,
    required String text,
    VoidCallback? onTap,
    bool showArrow = false,
  }) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: onTap != null ? Colors.white : Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5DEC9)),
        boxShadow: onTap != null ? [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ] : [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF5E543F)),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.montserrat(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF5E543F),
            ),
          ),
          if (showArrow && onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF5E543F)),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }

  Widget _buildTransactionTypeButton({
    required String title,
    required IconData icon,
    required Color selectedColor,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? const Color(0xFFE5DEC9) : Colors.transparent,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? selectedColor : const Color(0xFF5E543F),
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: GoogleFonts.montserrat(
                color: isSelected ? selectedColor : const Color(0xFF5E543F),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryButton(String categoryName) {
    final isSelected = _category == categoryName;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _category = categoryName),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              categoryName,
              style: GoogleFonts.montserrat(
                color: isSelected
                    ? const Color(0xFF01565B)
                    : const Color(0xFF5E543F),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentModeChip(String mode) {
    final isSelected = _paymentMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _paymentMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF9E6) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? const Color(0xFFDFBA6B)
                : const Color(0xFFE5DEC9),
          ),
        ),
        child: Text(
          mode,
          style: GoogleFonts.montserrat(
            color: isSelected
                ? const Color(0xFF735C0F)
                : const Color(0xFF5E543F),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildPartyAutocomplete() {
    return LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<PartyModel>(
        focusNode: _partyFocusNode,
        textEditingController: _partyController,
        optionsBuilder: (TextEditingValue textEditingValue) {
          final queryText = textEditingValue.text.trim();
          final queryLower = queryText.toLowerCase();
          final parties = ref.read(partiesStreamProvider).value ?? [];

          if (queryText.isEmpty) {
            final recent = parties.toList()
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
            return recent.take(5);
          }

          final matches = parties.where((party) {
            return party.name.toLowerCase().contains(queryLower) ||
                party.phone.contains(queryLower);
          }).toList();

          final hasExactMatch = matches.any((party) => party.name.toLowerCase() == queryLower);
          if (!hasExactMatch) {
            matches.add(
              PartyModel(
                id: 'ADD_NEW_PARTY_PLACEHOLDER',
                name: queryText,
                type: '',
                phone: '',
                email: '',
                address: '',
                cashBalance: 0.0,
                goldBalanceGrams: 0.0,
                silverBalanceGrams: 0.0,
                diamondBalanceCarats: 0.0,
                openingCashBalance: 0.0,
                openingGoldBalanceGrams: 0.0,
                openingDiamondBalanceCarats: 0.0,
                createdAt: TimeUtils.now,
                updatedAt: TimeUtils.now,
              ),
            );
          }

          return matches;
        },
        displayStringForOption: (PartyModel option) => option.name,
        onSelected: (PartyModel selection) async {
          if (selection.id == 'ADD_NEW_PARTY_PLACEHOLDER') {
            final newId = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (context) => QuickAddPartyBottomSheet(initialName: selection.name),
            );
            if (newId != null && newId is String) {
              final list = ref.read(partiesStreamProvider).value ?? [];
              final found = list.where((p) => p.id == newId).firstOrNull;
              if (found != null) {
                setState(() {
                  _selectedParty = found;
                  _partyController.text = found.name;
                  _pendingPartyId = null;
                });
              } else {
                setState(() => _pendingPartyId = newId);
              }
            } else {
              _partyController.clear();
              setState(() => _selectedParty = null);
            }
          } else {
            setState(() => _selectedParty = selection);
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _partyFocusNode.unfocus();
          });
        },
        fieldViewBuilder:
            (context, textEditingController, focusNode, onFieldSubmitted) {
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                inputFormatters: [UpperCaseTextFormatter()],
                style: GoogleFonts.montserrat(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search party name or phone...',
                  hintStyle: GoogleFonts.montserrat(
                    color: Colors.grey.shade500,
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Color(0xFF5E543F),
                    size: 18,
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFDFBA6B)),
                  ),
                  suffixIcon:
                      _selectedParty != null ||
                          textEditingController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            textEditingController.clear();
                            setState(() => _selectedParty = null);
                          },
                        )
                      : null,
                ),
                onSubmitted: (String value) {
                  onFieldSubmitted();
                },
              );
            },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 8,
              shadowColor: Colors.black.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: 200,
                  maxWidth: constraints.maxWidth,
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (BuildContext context, int index) {
                    final option = options.elementAt(index);
                    final isPlaceholder = option.id == 'ADD_NEW_PARTY_PLACEHOLDER';

                    if (isPlaceholder) {
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFFEEB3),
                          radius: 16,
                          child: Icon(
                            Icons.add,
                            color: Color(0xFF735C0F),
                            size: 16,
                          ),
                        ),
                        title: Text(
                          'Create new: "${option.name}"',
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF735C0F),
                          ),
                        ),
                        subtitle: Text(
                          'Tap to add customer details',
                          style: GoogleFonts.montserrat(
                            fontSize: 11,
                            color: Colors.black54,
                          ),
                        ),
                        dense: true,
                        onTap: () => onSelected(option),
                      );
                    }

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFF4EDE4),
                        radius: 16,
                        child: Text(
                          option.name.isNotEmpty
                              ? option.name[0].toUpperCase()
                              : '?',
                          style: GoogleFonts.montserrat(
                            color: const Color(0xFF735C0F),
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      title: _buildHighlightText(
                        option.name,
                        _partyController.text,
                      ),
                      subtitle: option.phone.isNotEmpty
                          ? Text(
                              option.phone,
                              style: GoogleFonts.montserrat(fontSize: 11),
                            )
                          : null,
                      dense: true,
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHighlightText(String text, String query) {
    if (query.isEmpty)
      return Text(
        text,
        style: GoogleFonts.montserrat(
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
      );
    final matchIndex = text.toLowerCase().indexOf(query.toLowerCase());
    if (matchIndex == -1)
      return Text(
        text,
        style: GoogleFonts.montserrat(
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
      );
    return RichText(
      text: TextSpan(
        text: text.substring(0, matchIndex),
        style: GoogleFonts.montserrat(
          color: Colors.black87,
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        children: [
          TextSpan(
            text: text.substring(matchIndex, matchIndex + query.length),
            style: GoogleFonts.montserrat(
              color: const Color(0xFFDFBA6B),
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          TextSpan(
            text: text.substring(matchIndex + query.length),
            style: GoogleFonts.montserrat(
              color: Colors.black87,
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTransaction() async {
    if (_selectedParty == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a party')));
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Determine TransactionType
      TransactionType tType = TransactionType.sale; // default
      if (_transactionType == 'IN') {
        if (_category == 'Money')
          tType = TransactionType.receipt;
        else
          tType = TransactionType.metalIn;
      } else {
        if (_category == 'Money')
          tType = TransactionType.payment;
        else
          tType = TransactionType.metalOut;
      }

      // Determine PaymentMode
      PaymentMode pMode = PaymentMode.cash;
      if (_category == 'Money') {
        if (_paymentMode == 'Cash')
          pMode = PaymentMode.cash;
        else if (_paymentMode == 'UPI')
          pMode = PaymentMode.upi;
        else if (_paymentMode == 'RTGS')
          pMode = PaymentMode.rtgs;
      } else {
        pMode = PaymentMode.metal;
      }

      // Parse values
      double cashAmt =
          double.tryParse(_amountController.text.replaceAll(',', '')) ?? 0.0;
      double metalWt = 0.0;
      if (_category == 'Gold')
        metalWt = double.tryParse(_weightController.text) ?? 0.0;
      if (_category == 'Diamond')
        metalWt = double.tryParse(_caratController.text) ?? 0.0;

      String metalP = '';
      if (_category == 'Gold') metalP = _purityController.text.trim();
      if (_category == 'Diamond') metalP = '${_piecesController.text.trim()} p';

      final date = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

      final success = await ref
          .read(transactionNotifierProvider.notifier)
          .createTransaction(
            partyId: _selectedParty!.id,
            partyName: _selectedParty!.name,
            partyPhone: _selectedParty!.phone,
            type: tType,
            paymentMode: pMode,
            cashAmount: cashAmt,
            metalType: _category == 'Money' ? '' : _category.toLowerCase(),
            metalWeight: metalWt,
            metalPurity: metalP,
            notes: _notesController.text.trim(),
            date: date,
          );

      if (success && mounted) {
        Navigator.pop(context); // Close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Quick Entry saved successfully')),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Save may have failed. Please check ledger before retrying.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An error occurred while saving')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

class _IndianCurrencyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    }

    String cleanText = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cleanText.isEmpty) {
      return newValue.copyWith(text: '');
    }

    try {
      int value = int.parse(cleanText);
      final formatter = NumberFormat.decimalPattern('en_IN');
      String formattedText = formatter.format(value);

      return newValue.copyWith(
        text: formattedText,
        selection: TextSelection.collapsed(offset: formattedText.length),
      );
    } catch (e) {
      return oldValue;
    }
  }
}
