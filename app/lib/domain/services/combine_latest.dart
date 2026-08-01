import 'dart:async';

/// Minimal combine-latest for exactly two streams — merges the latest
/// value from each into one reactive value via [combine]. A ~20-line,
/// well-understood pattern; not worth an `rxdart` dependency for this.
/// Shared between `ItemRepository` (direct items + recurring occurrences)
/// and the UI layer (an item stream + an external-calendar-event stream,
/// §9).
Stream<C> combineLatest2<A, B, C>(
  Stream<A> a,
  Stream<B> b,
  C Function(A, B) combine,
) {
  late StreamController<C> controller;
  A? latestA;
  B? latestB;
  var hasA = false;
  var hasB = false;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;

  void emit() {
    if (hasA && hasB) controller.add(combine(latestA as A, latestB as B));
  }

  controller = StreamController<C>.broadcast(
    onListen: () {
      subA = a.listen((v) {
        latestA = v;
        hasA = true;
        emit();
      }, onError: controller.addError);
      subB = b.listen((v) {
        latestB = v;
        hasB = true;
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return controller.stream;
}
