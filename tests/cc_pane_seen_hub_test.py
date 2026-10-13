# Run: python3 tests/cc_pane_seen_hub_test.py bin/cc-pane-seen   (throwaway tmux server -L zhub; never touches yours)
# Local session "in" shown in a tile of hub session "hub/t" (same server, like tw). Click tile -> seen?
import os, pty, sys, time, subprocess, struct, fcntl, termios, threading
seen_bin = sys.argv[1]
T = ["tmux", "-L", "zhub", "-f", os.path.expanduser("~/.tmux.conf")]
subprocess.run(T + ["kill-server"], capture_output=True)
subprocess.run(T + ["new", "-d", "-s", "in", "-x", "100", "-y", "14"])
subprocess.run(T + ["new", "-d", "-s", "hub/t", "-x", "100", "-y", "30", "TMUX= tmux -L zhub attach -t in"])
subprocess.run(T + ["split-window", "-v", "-t", "hub/t"])          # tile 2: plain shell, active
sock = subprocess.run(T + ["display", "-p", "#{socket_path}"], capture_output=True, text=True).stdout.strip()
env = dict(os.environ, TMUX=f"{sock},0,0")
target = subprocess.run(T + ["display", "-p", "-t", "in:0.0", "#{pane_id}"], capture_output=True, text=True).stdout.strip()
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ.pop("TMUX", None); os.execvp("tmux", T + ["attach", "-t", "hub/t"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
threading.Thread(target=lambda: [os.read(fd, 65536) for _ in iter(int, 1)], daemon=True).start()
time.sleep(2.5)
os.write(fd, b"\x1b[I"); time.sleep(0.5)
for yy in (3, 20):
    os.write(fd, f"\x1b[<0;20;{yy}M".encode()); time.sleep(0.05); os.write(fd, f"\x1b[<0;20;{yy}m".encode()); time.sleep(0.6)
ok = lambda name, got, want: print(("PASS" if got == want else "FAIL"), name, "got", got, "want", want)
one = lambda: subprocess.run([seen_bin, target], env=env).returncode
ok("hub focused, other tile active", one(), 1)
w = subprocess.Popen([seen_bin, "--watch", target, "15", "1"], env=env); time.sleep(1.5)
os.write(fd, b"\x1b[<0;20;3M"); time.sleep(0.05); os.write(fd, b"\x1b[<0;20;3m")   # click tile 1
rc = w.wait(6); ok("click the tile -> watch fires", rc, 0)
ok("now seen", one(), 0)
os.write(fd, b"\x1b[O"); time.sleep(0.5); ok("terminal loses focus -> not seen", one(), 1)
subprocess.run(T + ["kill-server"], capture_output=True)
