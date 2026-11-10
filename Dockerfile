# syntax=docker/dockerfile:1

# ---- build stage -------------------------------------------------------------
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace

# Copy the build definition first so source-only changes don't invalidate this layer.
COPY gradlew settings.gradle build.gradle ./
COPY gradle gradle
COPY src src

# BuildKit cache mount keeps the Gradle wrapper distribution and dependency cache
# between builds without baking them into an image layer.
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew bootJar --no-daemon -x test

# Split the fat jar into layers (dependencies change rarely, application code often),
# so rebuilt images only ship the layers that actually changed.
RUN java -Djarmode=tools -jar build/libs/app.jar extract --layers --destination extracted

# ---- runtime stage -----------------------------------------------------------
FROM eclipse-temurin:25-jre
RUN groupadd --system app && useradd --system --gid app --no-create-home app
WORKDIR /app

COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./

USER app
EXPOSE 8080
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75"
ENTRYPOINT ["java", "-jar", "app.jar"]
