FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jre-headless \
    libssl3 \
    libusb-1.0-0 \
    libudev1 \
    zlib1g \
    libzstd1 \
    libcap2 \
    && rm -rf /var/lib/apt/lists/*

COPY hailo-ollama /usr/bin/hailo-ollama
RUN chmod +x /usr/bin/hailo-ollama
COPY hailo-ollama-share /usr/share/hailo-ollama
COPY libhailort.so.5.3.0 /usr/lib/libhailort.so.5.3.0
RUN ln -s /usr/lib/libhailort.so.5.3.0 /usr/lib/libhailort.so && ldconfig

COPY application-standard-exec.jar /application.jar

EXPOSE 9200 9201 11434

ENTRYPOINT ["java", "-jar", "/application.jar"]
