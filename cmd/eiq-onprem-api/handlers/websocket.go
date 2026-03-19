package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

// WebSocketEvent represents a real-time event
type WebSocketEvent struct {
	Type      string      `json:"type"`
	Timestamp string      `json:"timestamp"`
	Data      interface{} `json:"data"`
}

// Client represents a connected WebSocket client
type Client struct {
	ID   string
	Conn *websocket.Conn
	Send chan WebSocketEvent
}

// Hub manages WebSocket clients and broadcasts
type Hub struct {
	clients    map[*Client]bool
	broadcast  chan WebSocketEvent
	register   chan *Client
	unregister chan *Client
	mu         sync.RWMutex
}

// Global hub instance
var hub *Hub

func init() {
	hub = &Hub{
		yclients:    make(map[*Client]bool),
		broadcast:   make(chan WebSocketEvent, 256),
		register:    make(chan *Client),
		unregister:  make(chan *Client),
	}
	go hub.run()
}

// run manages hub operations (immutable event pattern)
func (h *Hub) run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client] = true
			h.mu.Unlock()
			log.Printf("WebSocket client registered: %s", client.ID)

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.Send)
			}
			h.mu.Unlock()
			log.Printf("WebSocket client unregistered: %s", client.ID)

		case event := <-h.broadcast:
			h.mu.RLock()
			for client := range h.clients {
				select {
				case client.Send <- event:
				default:
					// Client's send channel is full, skip this client
				}
			}
			h.mu.RUnlock()
		}
	}
}

// WebSocketHandler upgrades HTTP connection to WebSocket
func WebSocketHandler(w http.ResponseWriter, r *http.Request) {
	upgrader := websocket.Upgrader{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		CheckOrigin: func(r *http.Request) bool {
			// In production, validate origin properly
			return true
		},
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}

	// Create client
	client := &Client{
		ID:   r.Header.Get("X-Client-ID"),
		Conn: conn,
		Send: make(chan WebSocketEvent, 256),
	}

	if client.ID == "" {
		client.ID = fmt.Sprintf("client-%d", len(hub.clients))
	}

	// Register client
	hub.register <- client

	// Start client goroutines
	go clientRead(client)
	go clientWrite(client)
}

// clientRead reads messages from WebSocket
func clientRead(client *Client) {
	defer func() {
		hub.unregister <- client
		client.Conn.Close()
	}()

	client.Conn.SetReadDeadline(func() {
		// Handle read timeout if needed
	})

	for {
		var msg map[string]interface{}
		err := client.Conn.ReadJSON(&msg)
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			return
		}

		// Process client message if needed
		log.Printf("WebSocket message from %s: %v", client.ID, msg)
	}
}

// clientWrite writes messages to WebSocket
func clientWrite(client *Client) {
	defer client.Conn.Close()

	for event := range client.Send {
	client.Conn.SetWriteDeadline(func() {
			// Handle write timeout if needed
		})

		if err := client.Conn.WriteJSON(event); err != nil {
			return
		}
	}
}

// BroadcastDeviceStatus broadcasts device status change
func BroadcastDeviceStatus(deviceID, hostname, status string) {
	event := WebSocketEvent{
		Type:      "device_status",
		Timestamp: time.Now().Format(time.RFC3339),
		Data: map[string]interface{}{
			"device_id": deviceID,
			"hostname":  hostname,
			"status":    status,
		},
	}
	hub.broadcast <- event
}

// BroadcastScanProgress broadcasts scan progress
func BroadcastScanProgress(scanID string, progress int, total int) {
	event := WebSocketEvent{
		Type:      "scan_progress",
		Timestamp: time.Now().Format(time.RFC3339),
		Data: map[string]interface{}{
			"scan_id":  scanID,
			"progress": progress,
			"total":    total,
		},
	}
	hub.broadcast <- event
}

// BroadcastRemediationUpdate broadcasts remediation status
func BroadcastRemediationUpdate(deviceID string, remediationType string, status string) {
	event := WebSocketEvent{
		Type:      "remediation_update",
		Timestamp: time.Now().Format(time.RFC3339),
		Data: map[string]interface{}{
			"device_id":      deviceID,
			"type":           remediationType,
			"status":         status,
		},
	}
	hub.broadcast <- event
}

// HealthCheck endpoint for WebSocket connectivity
func HealthCheckHandler(w http.ResponseWriter, r *http.Request) {
	hub.mu.RLock()
	clientCount := len(hub.clients)
	hub.mu.RUnlock()

	health := map[string]interface{}{
		"status":  "healthy",
		"clients": clientCount,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(health)
}
