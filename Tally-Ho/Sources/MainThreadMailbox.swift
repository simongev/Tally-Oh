//
//  MainThreadMailbox.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Handing per-frame work from the render thread to main without one block per frame (#15).
//
//  The render thread runs at 60 Hz and used to post a `DispatchQueue.main.async` block for the HUD
//  every frame, plus one for the yaw hold. Behind the 4 Hz `updateVisualization` those piled up and
//  then ran back to back, which is what made the HUD stutter. Each mailbox keeps at most one block
//  queued: the render thread posts into it, and only the post that finds it empty schedules a drain.
//

import Foundation

enum MainThreadMailbox {

    /// Latest wins: for state where only the newest value matters, such as the HUD's geometry for a
    /// frame. A value posted while an earlier one is still waiting replaces it.
    final class Latest<Value> {
        private let lock = NSLock()
        private var pending: Value?
        private var scheduled = false

        init() {}

        /// Leave `value` for main. True when the caller must schedule a drain: nothing was waiting,
        /// so no block is queued yet.
        func post(_ value: Value) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending = value
            guard !scheduled else { return false }
            scheduled = true
            return true
        }

        /// Main thread, from the scheduled block: the newest value, if any, and the mailbox open for
        /// the next schedule.
        func take() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            let value = pending
            pending = nil
            scheduled = false
            return value
        }
    }

    /// Every value, in order, drained in one block: for a stream where each value counts, such as the
    /// yaw hold's samples, whose three-frame median and step detection must see every frame. Nothing
    /// is dropped or reordered; only the number of queued blocks falls.
    final class Batch<Value> {
        private let lock = NSLock()
        private var pending: [Value] = []
        private var scheduled = false

        init() {}

        /// Append `value`. True when the caller must schedule a drain.
        func post(_ value: Value) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending.append(value)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }

        /// Main thread, from the scheduled block: everything posted since the last drain, oldest first.
        func takeAll() -> [Value] {
            lock.lock()
            defer { lock.unlock() }
            let values = pending
            pending.removeAll(keepingCapacity: true)
            scheduled = false
            return values
        }
    }
}
