import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swastik_mobile_app/core/services/notification_service.dart';
import 'package:swastik_mobile_app/core/utils/responsive_utils.dart';
import 'package:swastik_mobile_app/features/reminders/providers/reminder_navigation_provider.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/features/ledger/providers/realtime_sync_provider.dart';
import 'package:swastik_mobile_app/features/parties/providers/party_providers.dart';

import '../../../home/presentation/screens/home_screen.dart';
import '../../../entries/presentation/screens/entries_screen.dart';
import '../../../ledger/presentation/screens/ledger_screen.dart';
import '../../../reminders/presentation/screens/reminders_screen.dart';
import '../../../settings/presentation/screens/settings_screen.dart';
import '../providers/navigation_provider.dart';
import '../widgets/custom_bottom_nav_bar.dart';
import '../widgets/collapsible_sidebar.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  late final NotificationNavigationHandler _notificationNavigationHandler;
  bool _isSidebarCollapsed = false;

  // Persistent GlobalKey to reparent the bodyContent smoothly on orientation change
  final GlobalKey _bodyKey = GlobalKey(debugLabel: 'main_body_content_key');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationNavigationHandler = _handleNotificationNavigation;
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _scaleAnimation = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOutCubic),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0.0, 0.02), end: Offset.zero).animate(
          CurvedAnimation(parent: _fadeController, curve: Curves.easeOutCubic),
        );
    _fadeController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NotificationService().setNavigationHandler(
        _notificationNavigationHandler,
      );
      NotificationService().repairSchedulesFromServer(force: true);
      // Start the realtime data listener so entries made on any device appear
      // here live (for both admin and staff — MainScreen only mounts once
      // authenticated).
      ref.read(realtimeSyncProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(realtimeSyncProvider.notifier).stop();
    NotificationService().clearNavigationHandler(
      _notificationNavigationHandler,
    );
    _fadeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationService().repairSchedulesFromServer(force: true);
      // The polling streams can be throttled/paused while the app is in the
      // background, leaving stale data on return. Force an immediate refetch so
      // the admin/staff sees the latest entries the moment they reopen the app.
      ref.invalidate(statementTransactionsProvider);
      ref.invalidate(dailyBalancesStreamProvider);
      ref.invalidate(partiesStreamProvider);
      // Home table + summary totals are in-place providers — refresh them so the
      // dashboard shows the latest window and totals on resume.
      ref.read(homeTransactionsProvider.notifier).refresh();
      ref.read(transactionSummaryProvider.notifier).refresh();
      // The SSE socket is often silently killed while backgrounded — re-establish
      // it so live updates resume immediately.
      ref.read(realtimeSyncProvider.notifier).reconnect();
    }
  }

  void _handleNotificationNavigation(NotificationNavigationTarget target) {
    ref.read(navigationProvider.notifier).setIndex(3);

    final reminderNavigation = ref.read(reminderNavigationProvider.notifier);
    switch (target.type) {
      case NotificationNavigationType.reminder:
        reminderNavigation.showReminders(filter: 'All');
        break;
      case NotificationNavigationType.appointment:
        reminderNavigation.showAppointments(filter: 'All');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(navigationProvider);
    ref.listen<int>(navigationProvider, (previous, next) {
      if (previous != next) {
        _fadeController.forward(from: 0.0);
      }
    });
    final isTablet = AppResponsive.isTablet(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final showSidebar = isTablet && isLandscape;

    Widget bodyContent = FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: IndexedStack(
            key: _bodyKey,
            index: currentIndex,
            children: const [
              HomeScreen(),
              EntriesScreen(),
              LedgerScreen(),
              RemindersScreen(),
              SettingsScreen(),
            ],
          ),
        ),
      ),
    );

    if (showSidebar) {
      bodyContent = Row(
        children: [
          CollapsibleSidebar(
            currentIndex: currentIndex,
            onTap: (index) {
              ref.read(navigationProvider.notifier).setIndex(index);
            },
            isCollapsed: _isSidebarCollapsed,
            onToggleCollapse: () {
              setState(() {
                _isSidebarCollapsed = !_isSidebarCollapsed;
              });
            },
          ),
          Expanded(child: bodyContent),
        ],
      );
    }

    return Scaffold(
      backgroundColor: isTablet
          ? const Color(0xFFFAF6EE)
          : const Color(0xFFFDFBF7),
      body: bodyContent,
      bottomNavigationBar: showSidebar ? null : const CustomBottomNavBar(),
    );
  }
}
