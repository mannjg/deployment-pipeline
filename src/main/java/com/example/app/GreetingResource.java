package com.example.app;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * REST API endpoint for greetings
 * Provides endpoints to get personalized greeting messages
 */
@Path("/api/greetings")
@Produces(MediaType.APPLICATION_JSON)
public class GreetingResource {

    private final GreetingService greetingService;

    public GreetingResource(GreetingService greetingService) {
        this.greetingService = greetingService;
    }

    @GET
    public Greeting hello() {
        return greetingService.createGreeting("World");
    }

    @GET
    @Path("/{name}")
    public Greeting helloName(@PathParam("name") String name) {
        return greetingService.createGreeting(name);
    }

    @GET
    @Path("/version")
    @Produces(MediaType.TEXT_PLAIN)
    public String version() {
        return "v2.2.0 - Stable YAML Verification";
    }
}
