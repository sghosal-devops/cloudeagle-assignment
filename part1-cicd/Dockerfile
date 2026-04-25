# =============================================================================
#  Dockerfile — sync-service Spring Boot application
#
#  Build strategy: JAR-first (Maven runs in Jenkins, not here).
#  This Dockerfile only packages the pre-built JAR into a minimal JRE image.
#
#  Security:
#    - Non-root user (sync:sync, UID 1001)
#    - Minimal base image (eclipse-temurin JRE Alpine)
#    - HEALTHCHECK wired to Spring Boot Actuator /health
#
#  Build context: repository root
#  Dockerfile path: part1-cicd/Dockerfile
# =============================================================================

FROM eclipse-temurin:17-jre-alpine

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.title="sync-service" \
      org.opencontainers.image.vendor="CloudEagle" \
      org.opencontainers.image.description="Spring Boot sync service"

RUN addgroup -S -g 1001 sync \
 && adduser  -S -u 1001 -G sync -h /app -s /sbin/nologin sync

WORKDIR /app

# Jenkins normalizes the Maven output to this path before docker build.
COPY --chown=sync:sync target/sync-service.jar app.jar

RUN mkdir -p /app/config /app/logs \
 && chown -R sync:sync /app/config /app/logs

USER sync

EXPOSE 8080 8081

HEALTHCHECK --interval=30s \
            --timeout=10s \
            --start-period=60s \
            --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health 2>/dev/null \
      | grep -q '"status":"UP"'

ENTRYPOINT ["java", \
  "-Xms512m", \
  "-Xmx1g", \
  "-XX:+UseContainerSupport", \
  "-XX:MaxRAMPercentage=75.0", \
  "-Djava.awt.headless=true", \
  "-Dspring.config.additional-location=/app/config/application.yml", \
  "-jar", "app.jar"]
