package com.example.app;

import io.quarkus.test.junit.QuarkusIntegrationTest;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Testcontainers;

import static io.restassured.RestAssured.given;
import static org.hamcrest.CoreMatchers.containsString;
import static org.hamcrest.CoreMatchers.notNullValue;

/**
 * Integration tests using TestContainers with @QuarkusIntegrationTest
 * These tests run against the actual built artifact in a container
 */
@QuarkusIntegrationTest
@Testcontainers
class GreetingResourceIT {

    @Test
    void testHelloEndpointInContainer() {
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
    void testHelloNameEndpointInContainer() {
        given()
            .when()
            .get("/api/greetings/Container")
            .then()
            .statusCode(200)
            .contentType(ContentType.JSON)
            .body("message", containsString("Hello, Container!"))
            .body("timestamp", notNullValue());
    }

    @Test
    void testHealthEndpointInContainer() {
        given()
            .when()
            .get("/health/ready")
            .then()
            .statusCode(200);
    }
}
