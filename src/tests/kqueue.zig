const std = @import("std");
const expect = std.testing.expect;

test "Hard Reset" {
    // Have a client connect, send half a message, and then kill the client process with
}

test "One-way Close" {
    // The client sends a complete message and immediately calls shutdown(fd, SHUT_WR) (sending a FIN),
    // but leaves its read-end open. Your server should read the EOF, finish processing the message in
    // the worker thread, flush the response to the client, and then fully close the socket.
}

test "Timeouts" {
    // Make a ton of connections, sending only 1 byte then nothing
    // connections should get timed out
}

test "Early Disconnect" {
    // A client connects but disconnects before server accepts the connection
}
