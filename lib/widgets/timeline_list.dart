import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/media_service.dart';
import 'message_bubble.dart';

/// Проверяет, нужно ли подгрузить историю при скролле вверх.
///
/// Вызывается из слушателя [ScrollController] родительского виджета.
/// Срабатывает, когда пользователь доскроллил до конца списка (верх истории)
/// и ещё не идёт загрузка.
void onScrollToLoadHistory(
  ScrollController scrollController,
  bool canLoadMore,
  bool isLoadingMore,
  VoidCallback onLoadMore,
) {
  if (scrollController.hasClients &&
      scrollController.position.pixels >=
          scrollController.position.maxScrollExtent - 100 &&
      !isLoadingMore &&
      canLoadMore) {
    onLoadMore();
  }
}

/// Виджет ленты сообщений (timeline) чата.
///
/// Выделен из [ChatRoomScreen] для переиспользования и упрощения.
/// Содержит [ListView.builder] с reverse: true, вычисляет date header
/// между днями, индикатор загрузки истории в конце списка
/// и находит repliedEvent по eventId в timeline.
///
/// Отображение отдельных сообщений делегируется [MessageBubble],
/// который также принимает флаг [MessageBubble.showDateHeader]
/// и самостоятельно рендерит заголовок даты.
class TimelineList extends StatelessWidget {
  /// Все события из timeline чата.
  final List<Event> events;

  /// ID текущего пользователя (для определения isMe).
  final String currentUserId;

  /// Можно ли загрузить ещё историю (есть ли предыдущие события).
  final bool canLoadMoreHistory;

  /// Идёт ли сейчас загрузка истории.
  final bool isLoadingHistory;

  /// ScrollController для ListView (управляется родителем).
  final ScrollController scrollController;

  /// Timeline (нужен для поиска repliedEvent по eventId).
  final Timeline? timeline;

  /// Ширина экрана (передаётся для ограничений бабблов).
  final double screenWidth;

  /// Вызывается при нажатии "Ответить" на сообщении.
  final void Function(Event) onReply;

  /// Вызывается при долгом нажатии на сообщение.
  final void Function(Event, bool) onLongPress;

  /// Вызывается для повторной отправки сообщения с ошибкой.
  final void Function(Event) onResend;

  /// Вызывается для удаления сообщения с ошибкой.
  final void Function(Event) onRemove;

  /// Вызывается для загрузки предыдущих сообщений (lazy loading).
  final VoidCallback onLoadMoreHistory;

  /// Сервис для загрузки и кеширования медиа.
  final MediaService mediaService;

  /// Вызывается при нажатии на изображение (открыть полноэкранно).
  final void Function(Event) onOpenImage;

  const TimelineList({
    super.key,
    required this.events,
    required this.currentUserId,
    required this.canLoadMoreHistory,
    required this.isLoadingHistory,
    required this.scrollController,
    this.timeline,
    required this.screenWidth,
    required this.onReply,
    required this.onLongPress,
    required this.onResend,
    required this.onRemove,
    required this.onLoadMoreHistory,
    required this.mediaService,
    required this.onOpenImage,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(10),
      reverse: true,
      itemCount: events.length + (canLoadMoreHistory ? 1 : 0),
      itemBuilder: (context, index) {
        // ===== Индикатор загрузки истории в конце списка =====
        if (index == events.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final event = events[index];
        final isMe = event.senderId == currentUserId;

        // Пропускаем не Message/Encrypted события
        if (event.type != EventTypes.Message &&
            event.type != EventTypes.Encrypted) {
          return const SizedBox.shrink();
        }

        // ===== Date header: показываем, если день сменился =====
        final showDateHeader = index == events.length - 1 ||
            events[index + 1].originServerTs.day !=
                event.originServerTs.day;

        // ===== Поиск repliedEvent по eventId в timeline =====
        Event? repliedEvent;
        final replyToId = event.inReplyToEventId();
        if (replyToId != null && timeline != null) {
          try {
            repliedEvent =
                timeline!.events.firstWhere((e) => e.eventId == replyToId);
          } catch (_) {
            // repliedEvent остаётся null — цитируемое событие не найдено
          }
        }

        // ===== Баббл сообщения (включает date header внутри) =====
        return MessageBubble(
          key: ValueKey(event.eventId),
          event: event,
          isMe: isMe,
          showDateHeader: showDateHeader,
          repliedEvent: repliedEvent,
          currentUserId: currentUserId,
          screenWidth: screenWidth,
          mediaService: mediaService,
          onReply: onReply,
          onLongPress: onLongPress,
          onResend: onResend,
          onRemove: onRemove,
          onOpenImage: onOpenImage,
        );
      },
    );
  }
}
