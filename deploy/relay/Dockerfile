# Build context must contain only the frozen Linux binary and a trusted CA bundle.
FROM scratch
COPY voice-web /voice-web
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENTRYPOINT ["/voice-web", "relay"]
