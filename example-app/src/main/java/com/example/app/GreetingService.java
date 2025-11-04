package com.example.app;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Business logic for creating greetings
 */
@ApplicationScoped
public class GreetingService {

    public Greeting createGreeting(String name) {
        if (name == null || name.trim().isEmpty()) {
            throw new IllegalArgumentException("Name cannot be null or empty");
        }

        String message = String.format("Hello, %s!", name);
        return new Greeting(message, System.currentTimeMillis());
    }
}
