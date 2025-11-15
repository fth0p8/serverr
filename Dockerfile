# Dockerfile — debug build: prints ngrok logs and status to Railway logs
FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.utf8

# install required packages
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
    locales \
    openssh-server \
    wget \
    unzip \
    ca-certificates \
    curl \
    net-tools \
    iproute2 \
 && rm -rf /var/lib/apt/lists/*

# generate locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 || true

# Download ngrok and place into /usr/local/bin
RUN wget -q -O /tmp/ngrok.zip "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.zip" \
 && unzip -q /tmp/ngrok.zip -d /tmp \
 && mv /tmp/ngrok /usr/local/bin/ngrok \
 && chmod +x /usr/local/bin/ngrok \
 && rm -f /tmp/ngrok.zip

# Prepare SSH server + root password
RUN mkdir -p /run/sshd \
 && sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true \
 && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true \
 && echo "root:zeno" | chpasswd

# Create zeno.sh inside the image (debug-friendly)
RUN cat > /zeno.sh <<'EOF'
#!/bin/bash
set -euo pipefail

echo "----- zeno.sh started -----"
date

# show presence of NGROK_TOKEN without printing it
if [ -n "${NGROK_TOKEN-}" ]; then
  token_len=${#NGROK_TOKEN}
  masked="****${NGROK_TOKEN: -4}"
  echo "NGROK_TOKEN present (length=${token_len}, last4=${masked})"
else
  echo "NGROK_TOKEN is NOT set"
fi

# determine ngrok binary
NGROK_BIN="/usr/local/bin/ngrok"
if [ ! -x "$NGROK_BIN" ]; then
  if [ -x "./ngrok" ]; then
    NGROK_BIN="./ngrok"
    echo "Using ./ngrok"
  else
    echo "ERROR: ngrok binary not found or not executable"
    ls -la /usr/local/bin || true
    exit 1
  fi
fi
echo "ngrok binary: $NGROK_BIN"

# configure ngrok if token provided
if [ -n "${NGROK_TOKEN-}" ]; then
  echo "Configuring ngrok token..."
  if ! "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN" > /tmp/ngrok_config.log 2>&1; then
    echo "ngrok config failed; /tmp/ngrok_config.log contents:"
    sed -n '1,200p' /tmp/ngrok_config.log || true
  else
    echo "ngrok config succeeded"
  fi

  echo "Starting ngrok tcp 22 (background). Output -> /tmp/ngrok_run.log"
  # start ngrok and let it log to file
  nohup "$NGROK_BIN" tcp 22 --log=stdout --log-format=logfmt > /tmp/ngrok_run.log 2>&1 &
  sleep 5

  # attempt repeatedly and then print full log so Railway logs include it
  echo "Fetching ngrok public URL (waiting up to 30s)..."
  found=""
  for i in 1 2 3 4 5 6; do
    url=$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -o 'tcp://[^"]*' || true)
    if [ -n "$url" ]; then
      echo "Found public URL: $url"
      found=1
      break
    else
      echo "Tunnel not ready yet (attempt $i)..."
      sleep 3
    fi
  done

  echo "---- /tmp/ngrok_run.log (last 200 lines) ----"
  sed -n '1,200p' /tmp/ngrok_run.log || true

  echo "---- /tmp/ngrok_config.log (last 200 lines) ----"
  sed -n '1,200p' /tmp/ngrok_config.log || true

  echo "---- ps aux (ngrok + sshd) ----"
  ps aux | grep -E "[n]grok|[s]shd" || true

  echo "---- Listening sockets (netstat / ss) ----"
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn || true
  else
    netstat -tulpn || true
  fi

  if [ -z "$found" ]; then
    echo "WARNING: No ngrok public URL found. See above logs for errors."
  fi
else
  echo "NGROK_TOKEN not provided; skipping ngrok"
fi

echo "Starting sshd..."
exec /usr/sbin/sshd -D
EOF

RUN chmod 755 /zeno.sh

EXPOSE 22 80 443 8080 8888 5130 5131 5132 5133 5134 5135 3306

CMD ["/bin/bash", "/zeno.sh"]
