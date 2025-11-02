package com.example.app;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.CoreMatchers.containsString;
import static org.hamcrest.CoreMatchers.notNullValue;

/**
 * Integration tests for GreetingResource using @QuarkusTest
 */
@QuarkusTest
class GreetingResourceTest {

    @Test
    void testHelloEndpoint() {
        given()
            .when()
            .get("/api/greetings")
            .then()
            .statusCode(200)
            .contentType(ContentType.JSON)
            .body("message", containsString("Hello, World!"))
            .body("timestamp", notNullValue());
    }

    @Test
    void testHelloNameEndpoint() {
        given()
            .when()
            .get("/api/greetings/Quarkus")
            .then()
            .statusCode(200)
            .contentType(ContentType.JSON)
            .body("message", containsString("Hello, Quarkus!"))
            .body("timestamp", notNullValue());
    }

    @Test
    void testHealthEndpoint() {
        given()
            .when()
            .get("/health")
            .then()
            .statusCode(200);
    }

    @Test
    void testHealthReadiness() {
        given()
            .when()
            .get("/health/ready")
            .then()
            .statusCode(200);
    }

    @Test
    void testHealthLiveness() {
        given()
            .when()
            .get("/health/live")
            .then()
            .statusCode(200);
    }

    @Test
    void testMetricsEndpoint() {
        given()
            .when()
            .get("/metrics")
            .then()
            .statusCode(200);
    }
}
