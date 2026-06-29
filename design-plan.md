# Design Plan

## Part 1 - MVC Chat Server

* Description
    1. A server handles requests from a small range of connections (2 - 1000)
    2. Clients login and can view incoming messages and send messages to other users
    3. No authentication
    4. Messages can be any length
    5. Maybe provide user search functionality
    6. Maybe make script or program to test client load

Use kqueue - BSD/MacOS specific
Single threaded

## Part 2 - Authentication

* Description
    1. Client can create a user and password
    2. Connections or messages are authenticated
    3. Further research needs to be done about what makes this secure
