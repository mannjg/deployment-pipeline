package com.example.app;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for GreetingService
 */
class GreetingServiceTest {

    private final GreetingService service = new GreetingService();

    @Test
    void testCreateGreeting() {
        Greeting greeting = service.createGreeting("Alice");

        assertNotNull(greeting);
        assertEquals("Hello, Alice!", greeting.getMessage());
        assertTrue(greeting.getTimestamp() > 0);
    }

    @Test
    void testCreateGreetingWithEmptyName() {
        assertThrows(IllegalArgumentException.class, () -> {
            service.createGreeting("");
        });
    }

    @Test
    void testCreateGreetingWithNullName() {
        assertThrows(IllegalArgumentException.class, () -> {
            service.createGreeting(null);
        });
    }

    @Test
    void testCreateGreetingWithWhitespaceName() {
        assertThrows(IllegalArgumentException.class, () -> {
            service.createGreeting("   ");
        });
    }
}
