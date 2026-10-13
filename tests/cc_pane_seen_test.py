# Run: python3 tests/cc_pane_seen_test.py bin/cc-pane-seen   (throwaway tmux server -L zseen; never touches yours)
# Throwaway tmux server: check cc-pane-seen one-shot + --watch against focus/pane changes.
import os, pty, sys, time, subprocess, struct, fcntl, termios, threading
seen_bin = sys.argv[1]
T = ["tmux", "-L", "zseen", "-f", "/dev/null"]
subprocess.run(T + ["kill-server"], capture_output=True)
subprocess.run(T + ["new", "-d", "-s", "s", "-x", "100", "-y", "30"]); subprocess.run(T + ["split-window", "-h", "-t", "s"])
subprocess.run(T + ["set", "-g", "focus-events", "on"])
sock = subprocess.run(T + ["display", "-p", "#{socket_path}"], capture_output=True, text=True).stdout.strip()
env = dict(os.environ, TMUX=f"{sock},0,0")
target = subprocess.run(T + ["display", "-p", "-t", "s:0.0", "#{pane_id}"], capture_output=True, text=True).stdout.strip()
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ.pop("TMUX", None); os.execvp("tmux", T + ["attach", "-t", "s"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
threading.Thread(target=lambda: [os.read(fd, 65536) for _ in iter(int, 1)], daemon=True).start()
time.sleep(1.5)
one = lambda: subprocess.run([seen_bin, target], env=env).returncode
sel = lambda p: subprocess.run(T + ["select-pane", "-t", f"s:0.{p}"])
foc = lambda on: (os.write(fd, b"\x1b[I" if on else b"\x1b[O"), time.sleep(0.3))
ok = lambda name, got, want: print(("PASS" if got == want else "FAIL"), name, "got", got, "want", want)
foc(False); sel(1); ok("unfocused + other pane", one(), 1)
foc(True); ok("focused + other pane", one(), 1)
sel(0); ok("focused + this pane", one(), 0)
foc(False); ok("unfocused + this pane", one(), 1)
# --watch: starts unseen (unfocused); focusing the terminal on this pane fires it
w = subprocess.Popen([seen_bin, "--watch", target, "10", "1"], env=env); time.sleep(1.5)
ok("watch still waiting while unseen", w.poll(), None)
foc(True); t0 = time.time(); rc = w.wait(5); ok(f"watch fires on focus ({time.time()-t0:.1f}s)", rc, 0)
# --watch starting SEEN must not fire until it leaves and comes back
w = subprocess.Popen([seen_bin, "--watch", target, "10", "1"], env=env); time.sleep(2.2)
ok("already seen -> no fire", w.poll(), None)
sel(1); time.sleep(1.2); sel(0); rc = w.wait(5); ok("leave + click back -> fires", rc, 0)
# timeout path
foc(False); ok("watch timeout -> 1", subprocess.run([seen_bin, "--watch", target, "2", "1"], env=env).returncode, 1)
ok("gone target -> 2", subprocess.run([seen_bin, "%999"], env=env).returncode, 2)
subprocess.run(T + ["kill-server"], capture_output=True)
