import sys
import threading
import time
from dataclasses import dataclass

import psycopg2

import doom_sql as sql
from doom_config import DB_DSN, SCREEN_H, SCREEN_W, tune_replanning


@dataclass(frozen=True)
class RenderSnapshot:
    frame_id: int
    frame: object
    render_seconds: float
    completed_at: float
    error: object


class RenderWorker:
    """Own the renderer thread and its synchronized generation state."""

    def __init__(self, map_id, player_thing_id, skill):
        self._condition = threading.Condition()
        self._stop = False
        self._request_id = 0
        self._completed_request_id = 0
        self._frame_id = 0
        self._frame = None
        self._render_seconds = 0.0
        self._completed_at = 0.0
        self._error = None
        self._map_id = map_id
        self._player_thing_id = player_thing_id
        self._skill = skill
        self._pose = None
        self._alpha = 1.0
        self._detail = None
        self._last_error_log = 0.0
        self._suppressed_errors = 0
        self._context_generation = 0
        # A world to compile the renderer for before it is needed
        self._prepare_for = (map_id, player_thing_id, skill)
        self._warm_pose = None
        self._thread = threading.Thread(
            target=self._run, name="sql-renderer", daemon=True,
        )
        self._thread.start()

    def request(self, pose, map_id=None, player_thing_id=None, skill=None,
                invalidate=False, detail=None, alpha=1.0):
        # `alpha` is where in the current tic the frame sits, 0 at the last one
        # and 1 at this one. A player role sends that instead of `pose` and the
        # server interpolates; `pose` is still what the local renderer draws
        # and what a failure is reported with. 1.0 means "this tic".
        with self._condition:
            self._pose = pose
            self._alpha = alpha
            self._detail = detail
            if map_id is not None:
                self._map_id = map_id
            if player_thing_id is not None:
                self._player_thing_id = player_thing_id
            if skill is not None:
                self._skill = skill
            self._request_id += 1
            if invalidate:
                self._context_generation += 1
                self._frame = None
                self._frame_id += 1
                self._render_seconds = 0.0
                self._completed_at = 0.0
                self._error = None
            self._condition.notify()
            return self._frame_id

    def prefetch(self, map_id, player_thing_id, skill, pose=None):
        """Compile and warm the renderer for a world we are about to enter."""
        with self._condition:
            self._prepare_for = (map_id, player_thing_id, skill)
            self._warm_pose = pose
            self._condition.notify()

    def _log_failure(self, exc, pose, detail, context, elapsed):
        """Print a failed render to the terminal, at most twice a second."""
        now = time.perf_counter()
        with self._condition:
            if now - self._last_error_log < 0.5:
                self._suppressed_errors += 1
                return
            suppressed = self._suppressed_errors
            self._suppressed_errors = 0
            self._last_error_log = now
        map_id, player_thing_id, skill, generation = context
        lines = [
            f"[render error] {exc}",
            f"    took {elapsed * 1000.0:.1f} ms   map={map_id} "
            f"player={player_thing_id} skill={skill} gen={generation}",
            f"    pose  x={pose[0]:.4f} y={pose[1]:.4f} "
            f"z={pose[2]:.4f} angle={pose[3]:.4f}"
            if pose is not None else "    pose  <none>",
        ]
        if detail is not None:
            px, py, pz, pa, cx, cy, cz, ca, alpha = detail
            lines.append(
                f"    prev  x={px:.4f} y={py:.4f} z={pz:.4f} angle={pa:.4f}"
            )
            lines.append(
                f"    cur   x={cx:.4f} y={cy:.4f} z={cz:.4f} angle={ca:.4f}"
            )
            lines.append(
                f"    alpha {alpha:.4f}   step "
                f"dx={cx - px:.4f} dy={cy - py:.4f} dz={cz - pz:.4f} "
                f"dangle={((ca - pa + 180.0) % 360.0) - 180.0:.4f}"
            )
        if suppressed:
            lines.append(f"    ({suppressed} more suppressed)")
        print("\n".join(lines), file=sys.stderr, flush=True)

    def poll(self, previous_frame_id):
        with self._condition:
            frame = (self._frame
                     if self._frame_id != previous_frame_id else None)
            return RenderSnapshot(
                self._frame_id, frame, self._render_seconds,
                self._completed_at, self._error,
            )

    def close(self):
        with self._condition:
            self._stop = True
            self._condition.notify_all()
        self._thread.join(timeout=0.5)

    def _run(self):
        conn = None
        cur = None
        last_request = 0
        failures = 0
        try:
            conn = psycopg2.connect(DB_DSN)
            conn.autocommit = True
            cur = conn.cursor()
            tune_replanning(cur)
            prepared_for = None
            while True:
                with self._condition:
                    self._condition.wait_for(
                        lambda: self._stop
                        or self._request_id > last_request
                        or (self._prepare_for is not None
                            and self._prepare_for != prepared_for)
                    )
                    if self._stop:
                        return
                    prepare_for = self._prepare_for
                    warm_pose = self._warm_pose
                    request_id = self._request_id
                    pose = self._pose
                    alpha = self._alpha
                    detail = self._detail
                    context = (
                        self._map_id, self._player_thing_id, self._skill,
                        self._context_generation,
                    )

                if context[:3] != prepared_for and pose is not None:
                    prepare_for = context[:3]
                    warm_pose = pose
                if prepare_for is not None and prepare_for != prepared_for:
                    # Compile for this world, then execute twice so the replan
                    # is spent here rather than on the level's first frame.
                    if warm_pose is None:
                        try:
                            cur.execute(
                                """SELECT spawn_x, spawn_y, spawn_angle
                                   FROM things
                                   WHERE map_id=%s AND id=%s""",
                                prepare_for[:2])
                            row = cur.fetchone()
                            if row is not None:
                                warm_pose = (float(row[0]), float(row[1]),
                                             41.0, float(row[2]))
                        except Exception:
                            cur.connection.rollback()
                    try:
                        sql.prepare_renderer(cur, *prepare_for)
                        for _ in range(2):
                            try:
                                sql.render_frame(cur, *prepare_for,
                                                 warm_pose or pose or
                                                 (0.0, 0.0, 41.0, 0.0),
                                                 SCREEN_W, SCREEN_H, 1.0)
                            except Exception:
                                cur.connection.rollback()
                        prepared_for = prepare_for
                    except Exception:
                        cur.connection.rollback()
                        try:
                            sql.prepare_renderer(cur)
                        except Exception:
                            cur.connection.rollback()
                        prepared_for = prepare_for
                    if request_id <= last_request:
                        continue

                started = time.perf_counter()
                try:
                    frame = sql.render_frame(
                        cur, *context[:3], pose, SCREEN_W, SCREEN_H, alpha,
                    )
                    completed_at = time.perf_counter()
                    elapsed = completed_at - started
                except Exception as exc:
                    with self._condition:
                        self._error = str(exc)
                    self._log_failure(exc, pose, detail, context,
                                      time.perf_counter() - started)
                    last_request = request_id
                    # Back off -> might fix itself after the player has moved.
                    failures += 1
                    time.sleep(min(0.5, 0.05 * failures))
                    continue

                with self._condition:
                    current_context = (
                        self._map_id, self._player_thing_id, self._skill,
                        self._context_generation,
                    )
                    # Never publish a frame that crossed a stage/skill change.
                    if current_context != context:
                        last_request = request_id
                        continue
                    self._frame = frame
                    self._frame_id += 1
                    self._completed_request_id = request_id
                    self._render_seconds = elapsed
                    self._completed_at = completed_at
                    self._error = None
                failures = 0
                last_request = request_id
        except Exception as exc:
            with self._condition:
                self._error = str(exc)
        finally:
            if cur is not None:
                cur.close()
            if conn is not None:
                conn.close()
