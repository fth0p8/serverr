# Dockerfile — self-contained (creates /zeno.sh automatically)
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

# Create zeno.sh inside the image (debug-friendly, won't print token)
RUN cat > /zeno.sh <<'EOF'\n#!/bin/bash\nset -euo pipefail\n\n# Debug helper: show token presence (not the full token)\nif [ -n \"${NGROK_TOKEN-}\" ]; then\n  token_len=${#NGROK_TOKEN}\n  masked=\"****${NGROK_TOKEN: -4}\"\n  echo \"NGROK_TOKEN present (length=${token_len}, last4=${masked})\"\nelse\n  echo \"NGROK_TOKEN is NOT set\"\nfi\n\n# Select ngrok binary\nNGROK_BIN=\"/usr/local/bin/ngrok\"\nif [ ! -x \"$NGROK_BIN\" ]; then\n  if [ -x \"./ngrok\" ]; then\n    NGROK_BIN=\"./ngrok\"\n    echo \"Using ./ngrok\"\n  else\n    echo \"ERROR: ngrok binary not found or not executable\"\n    ls -la /usr/local/bin || true\n    exit 1\n  fi\nfi\n\necho \"ngrok binary: $NGROK_BIN\"\n\n# Configure ngrok (capture output to logs)\nif [ -n \"${NGROK_TOKEN-}\" ]; then\n  echo \"Configuring ngrok token...\"\n  if ! \"$NGROK_BIN\" config add-authtoken \"$NGROK_TOKEN\" > /tmp/ngrok_config.log 2>&1; then\n    echo \"ngrok config failed; /tmp/ngrok_config.log contents:\" \n    sed -n '1,200p' /tmp/ngrok_config.log || true\n  else\n    echo \"ngrok config succeeded\"\n  fi\n\n  echo \"Starting ngrok tcp 22 (background). Output -> /tmp/ngrok_run.log\"\n  nohup \"$NGROK_BIN\" tcp 22 > /tmp/ngrok_run.log 2>&1 &\n  sleep 1\n  ps aux | grep -E \"[n]grok\" || true\nelse\n  echo \"NGROK_TOKEN not provided; skipping ngrok\"\nfi\n\n# Start sshd in foreground so container stays alive\necho \"Starting sshd...\"\nexec /usr/sbin/sshd -D\nEOF

# Make script executable
RUN chmod 755 /zeno.sh

# Expose ports (including SSH)
EXPOSE 22 80 443 8080 8888 5130 5131 5132 5133 5134 5135 3306

# Use bash to run the script (so set -euo works)
CMD ["/bin/bash", "/zeno.sh"]
