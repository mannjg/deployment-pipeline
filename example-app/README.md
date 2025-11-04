# Example Application

A simple Quarkus application demonstrating the CI/CD pipeline with CUE-based deployments.

## Features

- **REST API**: Simple greeting endpoints
- **Health Checks**: Kubernetes-ready liveness and readiness probes
- **Metrics**: Prometheus-compatible metrics endpoint
- **TestContainers**: Integration tests with container-based testing

## Endpoints

- `GET /api/greetings` - Returns a greeting for "World"
- `GET /api/greetings/{name}` - Returns a personalized greeting
- `GET /health` - Combined health check
- `GET /health/live` - Liveness probe
- `GET /health/ready` - Readiness probe
- `GET /metrics` - Prometheus metrics

## Building

### Run tests

```bash
# Unit tests only
mvn test

# Unit + integration tests
mvn verify
```

### Build JAR

```bash
mvn package
```

### Build Docker image (with Jib)

```bash
mvn package jib:build \
    -Dimage.registry=nexus.local:5000 \
    -Dimage.group=example \
    -Dimage.name=example-app \
    -Dimage.tag=1.0.0-SNAPSHOT
```

### Run locally

```bash
mvn quarkus:dev
```

Then access: http://localhost:8080/api/greetings

## CI/CD Pipeline

The application uses a Jenkins pipeline defined in `Jenkinsfile`:

1. **Unit Tests**: Run on every commit
2. **Integration Tests**: Run on MR and merge to main
3. **Build & Publish**: On merge to main
   - Builds Docker image with Jib
   - Publishes to Nexus Docker registry
   - Publishes Maven artifacts to Nexus
4. **Update Deployment**: Updates k8s-deployments repository (dev branch)
5. **Create Promotion MR**: Creates draft MR for stage promotion

## Deployment Configuration

The `deployment/app.cue` file defines application-specific configuration that will be merged into the k8s-deployments repository by the CI/CD pipeline.

This includes:
- Application metadata
- Environment variables
- Health check configuration
- Service configuration
- Deployment strategy

## Technology Stack

- **Quarkus 3.17.7**: Supersonic Subatomic Java framework
- **Java 17**: LTS Java version
- **Maven 3.9.6**: Build tool
- **Jib**: Docker image builder (no Docker daemon required)
- **TestContainers**: Container-based integration testing
- **RESTEasy Reactive**: Reactive REST framework
- **Jackson**: JSON serialization
- **SmallRye Health**: Health check framework
- **Micrometer**: Metrics framework with Prometheus export

## Project Structure

```
example-app/
├── src/
│   ├── main/
│   │   ├── java/com/example/app/
│   │   │   ├── GreetingResource.java    # REST endpoint
│   │   │   ├── GreetingService.java     # Business logic
│   │   │   └── Greeting.java            # Data model
│   │   └── resources/
│   │       └── application.properties   # Configuration
│   └── test/
│       └── java/com/example/app/
│           ├── GreetingServiceTest.java # Unit tests
│           ├── GreetingResourceTest.java # @QuarkusTest
│           └── GreetingResourceIT.java  # Integration tests
├── deployment/
│   └── app.cue                         # CUE deployment config
├── Jenkinsfile                         # CI/CD pipeline
├── pom.xml                             # Maven configuration
└── README.md                           # This file
```

## Development

### Prerequisites

- JDK 17
- Maven 3.9+
- Docker (for integration tests)

### IDE Setup

Import as a Maven project. Most IDEs will automatically recognize the Quarkus project structure.

### Running Tests

```bash
# Unit tests (fast)
mvn test

# Integration tests (requires Docker)
mvn verify -DskipITs=false

# All tests
mvn clean verify
```

### Continuous Development

```bash
# Start in dev mode with live reload
mvn quarkus:dev
```

Then make changes to the code and see them reflected immediately at http://localhost:8080

## License

Example application for CI/CD pipeline demonstration.
# Trigger build
