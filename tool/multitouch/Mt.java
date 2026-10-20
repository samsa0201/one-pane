import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.lang.reflect.Method;

/** Multitouch injector, run as shell via app_process (see README.md). */
public class Mt {
  static Object im;
  static Method inject;
  static long hold;

  public static void main(String[] a) throws Exception {
    Class<?> c;
    try { c = Class.forName("android.hardware.input.InputManagerGlobal"); } // API 34+
    catch (ClassNotFoundException e) { c = Class.forName("android.hardware.input.InputManager"); }
    im = c.getMethod("getInstance").invoke(null);
    inject = c.getMethod("injectInputEvent", InputEvent.class, int.class);
    float[] f = new float[a.length];
    for (int i = 1; i < a.length; i++) f[i] = Float.parseFloat(a[i]);
    switch (a[0]) {
      case "swipe2": { // x y dx dy ms [gap] [holdMs before lifting]
        float g = a.length > 6 ? f[6] : 300;
        hold = a.length > 7 ? (long) f[7] : 0;
        gesture(f[1] - g / 2, f[2], f[1] + g / 2, f[2], f[3], f[4], f[3], f[4], (long) f[5]);
        break;
      }
      case "pinch": { // cx cy spreadFrom spreadTo ms  (horizontal fingers)
        float s0 = f[3] / 2, s1 = f[4] / 2;
        gesture(f[1] - s0, f[2], f[1] + s0, f[2], s0 - s1, 0, s1 - s0, 0, (long) f[5]);
        break;
      }
      case "tap2": { // x y [gap]
        float g = a.length > 3 ? f[3] : 300;
        gesture(f[1] - g / 2, f[2], f[1] + g / 2, f[2], 0, 0, 0, 0, 60);
        break;
      }
      case "dtap2": { // x y [gap] [pauseMs]
        float g = a.length > 3 ? f[3] : 300;
        long pause = a.length > 4 ? (long) f[4] : 120;
        gesture(f[1] - g / 2, f[2], f[1] + g / 2, f[2], 0, 0, 0, 0, 60);
        SystemClock.sleep(pause);
        gesture(f[1] - g / 2, f[2], f[1] + g / 2, f[2], 0, 0, 0, 0, 60);
        break;
      }
      case "tapdrag": { // x y dx dy ms [pauseMs]: tap, then a drag from the same point (double tap + slide)
        drag1(f[1], f[2], 0, 0, 40, 0);
        SystemClock.sleep(a.length > 6 ? (long) f[6] : 100);
        drag1(f[1], f[2], f[3], f[4], (long) f[5], 0);
        break;
      }
      case "holddrag": { // x y dx dy ms holdMs: press still for holdMs, then drag
        drag1(f[1], f[2], f[3], f[4], (long) f[5], (long) f[6]);
        break;
      }
      default: throw new IllegalArgumentException("swipe2|pinch|tap2|dtap2|tapdrag|holddrag");
    }
  }

  /** One finger from (x,y) by (dx,dy) over ms, after holding still for holdMs. */
  static void drag1(float x, float y, float dx, float dy, long ms, long holdMs) throws Exception {
    long down = SystemClock.uptimeMillis();
    send(down, down, MotionEvent.ACTION_DOWN, 1, x, y, 0, 0);
    if (holdMs > 0) SystemClock.sleep(holdMs);
    int steps = Math.max(1, (int) (ms / 10));
    for (int i = 1; i <= steps; i++) {
      SystemClock.sleep(ms / steps);
      send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, 1, x + dx * i / steps, y + dy * i / steps, 0, 0);
    }
    send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 1, x + dx, y + dy, 0, 0);
  }

  /** Finger 0 from (x0,y0) by (dx0,dy0), finger 1 from (x1,y1) by (dx1,dy1), over ms. */
  static void gesture(float x0, float y0, float x1, float y1, float dx0, float dy0, float dx1, float dy1, long ms)
      throws Exception {
    long down = SystemClock.uptimeMillis();
    send(down, down, MotionEvent.ACTION_DOWN, 1, x0, y0, x1, y1);
    SystemClock.sleep(10);
    send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, x0, y0, x1, y1);
    int steps = Math.max(1, (int) (ms / 10));
    for (int i = 1; i <= steps; i++) {
      float t = (float) i / steps;
      SystemClock.sleep(ms / steps);
      send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, 2,
          x0 + dx0 * t, y0 + dy0 * t, x1 + dx1 * t, y1 + dy1 * t);
    }
    float ex0 = x0 + dx0, ey0 = y0 + dy0, ex1 = x1 + dx1, ey1 = y1 + dy1;
    if (hold > 0) SystemClock.sleep(hold);
    send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2, ex0, ey0, ex1, ey1);
    send(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 1, ex0, ey0, ex1, ey1);
  }

  static void send(long down, long t, int action, int n, float x0, float y0, float x1, float y1) throws Exception {
    MotionEvent.PointerProperties[] pp = new MotionEvent.PointerProperties[n];
    MotionEvent.PointerCoords[] pc = new MotionEvent.PointerCoords[n];
    float[][] xy = {{x0, y0}, {x1, y1}};
    for (int i = 0; i < n; i++) {
      pp[i] = new MotionEvent.PointerProperties();
      pp[i].id = i;
      pp[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
      pc[i] = new MotionEvent.PointerCoords();
      pc[i].x = xy[i][0];
      pc[i].y = xy[i][1];
      pc[i].pressure = 1;
      pc[i].size = 1;
    }
    MotionEvent e = MotionEvent.obtain(down, t, action, n, pp, pc, 0, 0, 1, 1, 0, 0,
        InputDevice.SOURCE_TOUCHSCREEN, 0);
    inject.invoke(im, e, 2); // INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH
    e.recycle();
  }
}
