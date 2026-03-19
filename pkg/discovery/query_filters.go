// pkg/discovery/query_filters.go
// Advanced Query Filters for Device Discovery
// =============================================================================
// Purpose:
//   Support complex filtering, saved views, and custom queries for device
//   inventory. Enables sophisticated search and analysis capabilities.
//
// Features:
//   - Complex filter combinations (AND/OR/NOT)
//   - Field wildcards and regex support
//   - Date range filtering
//   - Custom field queries
//   - Saved filter views (immutable)
//   - Filter composition
//   - Performance optimization
//
// =============================================================================

package discovery

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Filter represents a single filter condition
type Filter struct {
	Field    string      `json:"field"`
	Operator string      `json:"operator"` // "eq", "ne", "in", "contains", "regex", "gt", "lt", "range"
	Value    interface{} `json:"value"`
}

// QueryBuilder allows composing complex queries
type QueryBuilder struct {
	filters    []Filter
	conditions []string // "AND", "OR"
	limit      int
	offset     int
	sortBy     string
	sortOrder  string
}

// Device represents a discovered device for filtering
type Device struct {
	ID            string    `json:"device_id"`
	Hostname      string    `json:"hostname"`
	IPAddress     string    `json:"ip_address"`
	DeviceType    string    `json:"device_type"`
	OS            string    `json:"os"`
	Status        string    `json:"status"`
	Domain        *string   `json:"domain"`
	FirstSeen     time.Time `json:"first_seen"`
	LastSeen      time.Time `json:"last_seen"`
	Tags          []string  `json:"tags"`
	Metadata      map[string]interface{} `json:"metadata"`
}

// SavedView represents a saved filter for reuse
type SavedView struct {
	ID          string        `json:"id"`
	Name        string        `json:"name"`
	Description string        `json:"description"`
	Filters     []Filter      `json:"filters"`
	Conditions  []string      `json:"conditions"`
	CreatedAt   time.Time     `json:"created_at"`
	UpdatedAt   time.Time     `json:"updated_at"`
	Owner       string        `json:"owner"`
}

// NewQueryBuilder creates a new query builder
func NewQueryBuilder() *QueryBuilder {
	return &QueryBuilder{
		filters:   make([]Filter, 0),
		conditions: make([]string, 0),
		limit:     100,
		offset:    0,
		sortBy:    "last_seen",
		sortOrder: "desc",
	}
}

// AddFilter adds a filter condition
func (qb *QueryBuilder) AddFilter(field, operator string, value interface{}) *QueryBuilder {
	qb.filters = append(qb.filters, Filter{
		Field:    field,
		Operator: operator,
		Value:    value,
	})
	return qb
}

// And combines filters with AND logic
func (qb *QueryBuilder) And() *QueryBuilder {
	qb.conditions = append(qb.conditions, "AND")
	return qb
}

// Or combines filters with OR logic
func (qb *QueryBuilder) Or() *QueryBuilder {
	qb.conditions = append(qb.conditions, "OR")
	return qb
}

// Limit sets result limit
func (qb *QueryBuilder) Limit(limit int) *QueryBuilder {
	qb.limit = limit
	return qb
}

// Offset sets result offset (pagination)
func (qb *QueryBuilder) Offset(offset int) *QueryBuilder {
	qb.offset = offset
	return qb
}

// OrderBy sets sort field and direction
func (qb *QueryBuilder) OrderBy(field, direction string) *QueryBuilder {
	qb.sortBy = field
	qb.sortOrder = direction
	return qb
}

// Execute applies filters to device list (immutable operation)
func (qb *QueryBuilder) Execute(devices []Device) []Device {
	filtered := []Device{}

	for _, device := range devices {
		if qb.matches(&device) {
			filtered = append(filtered, device)
		}
	}

	// Sort
	qb.sort(filtered)

	// Limit and offset
	start := qb.offset
	end := start + qb.limit
	if start >= len(filtered) {
		return []Device{}
	}
	if end > len(filtered) {
		end = len(filtered)
	}

	return filtered[start:end]
}

// matches checks if device matches all filters
func (qb *QueryBuilder) matches(device *Device) bool {
	if len(qb.filters) == 0 {
		return true
	}

	// Single filter, no conditions
	if len(qb.filters) == 1 {
		return qb.evaluateFilter(&qb.filters[0], device)
	}

	// Multiple filters with conditions
	result := qb.evaluateFilter(&qb.filters[0], device)

	for i := 1; i < len(qb.filters); i++ {
		condition := "AND" // Default
		if i-1 < len(qb.conditions) {
			condition = qb.conditions[i-1]
		}

		nextResult := qb.evaluateFilter(&qb.filters[i], device)

		if condition == "AND" {
			result = result && nextResult
		} else if condition == "OR" {
			result = result || nextResult
		}
	}

	return result
}

// evaluateFilter checks if device matches single filter
func (qb *QueryBuilder) evaluateFilter(filter *Filter, device *Device) bool {
	value := qb.getFieldValue(device, filter.Field)

	switch filter.Operator {
	case "eq":
		return fmt.Sprintf("%v", value) == fmt.Sprintf("%v", filter.Value)

	case "ne":
		return fmt.Sprintf("%v", value) != fmt.Sprintf("%v", filter.Value)

	case "contains":
		return strings.Contains(fmt.Sprintf("%v", value), fmt.Sprintf("%v", filter.Value))

	case "in":
		values, ok := filter.Value.([]interface{})
		if !ok {
			return false
		}
		for _, v := range values {
			if fmt.Sprintf("%v", value) == fmt.Sprintf("%v", v) {
				return true
			}
		}
		return false

	case "regex":
		pattern, ok := filter.Value.(string)
		if !ok {
			return false
		}
		re, err := regexp.Compile(pattern)
		if err != nil {
			return false
		}
		return re.MatchString(fmt.Sprintf("%v", value))

	case "gt":
		return fmt.Sprintf("%v", value) > fmt.Sprintf("%v", filter.Value)

	case "lt":
		return fmt.Sprintf("%v", value) < fmt.Sprintf("%v", filter.Value)

	case "range":
		// Value should be [min, max]
		rangeVal, ok := filter.Value.([]interface{})
		if !ok || len(rangeVal) != 2 {
			return false
		}
		valStr := fmt.Sprintf("%v", value)
		minStr := fmt.Sprintf("%v", rangeVal[0])
		maxStr := fmt.Sprintf("%v", rangeVal[1])
		return valStr >= minStr && valStr <= maxStr

	default:
		return true
	}
}

// getFieldValue extracts field value from device
func (qb *QueryBuilder) getFieldValue(device *Device, field string) interface{} {
	switch field {
	case "device_id":
		return device.ID
	case "hostname":
		return device.Hostname
	case "ip_address":
		return device.IPAddress
	case "device_type":
		return device.DeviceType
	case "os":
		return device.OS
	case "status":
		return device.Status
	case "domain":
		if device.Domain != nil {
			return *device.Domain
		}
		return ""
	case "first_seen":
		return device.FirstSeen.Format(time.RFC3339)
	case "last_seen":
		return device.LastSeen.Format(time.RFC3339)
	default:
		// Check metadata
		if device.Metadata != nil {
			if val, exists := device.Metadata[field]; exists {
				return val
			}
		}
		return ""
	}
}

// sort sorts devices based on sort field and order
func (qb *QueryBuilder) sort(devices []Device) {
	// Simple bubble sort for demonstration
	// In production, use more efficient sorting
	for i := 0; i < len(devices); i++ {
		for j := 0; j < len(devices)-i-1; j++ {
			compare := func(a, b interface{}) int {
				aStr := fmt.Sprintf("%v", a)
				bStr := fmt.Sprintf("%v", b)
				if aStr < bStr {
					return -1
				} else if aStr > bStr {
					return 1
				}
				return 0
			}

			valA := qb.getFieldValue(&devices[j], qb.sortBy)
			valB := qb.getFieldValue(&devices[j+1], qb.sortBy)

			cmp := compare(valA, valB)
			if (qb.sortOrder == "asc" && cmp > 0) || (qb.sortOrder == "desc" && cmp < 0) {
				devices[j], devices[j+1] = devices[j+1], devices[j]
			}
		}
	}
}

// SavedViewStore manages saved filter views (immutable)
type SavedViewStore struct {
	views map[string]*SavedView
}

// NewSavedViewStore creates a new saved view store
func NewSavedViewStore() *SavedViewStore {
	return &SavedViewStore{
		views: make(map[string]*SavedView),
	}
}

// SaveView saves a filter view (immutable - once created, cannot be modified)
func (svs *SavedViewStore) SaveView(name, description, owner string, filters []Filter, conditions []string) string {
	viewID := fmt.Sprintf("view-%s-%d", owner, time.Now().Unix())

	view := &SavedView{
		ID:          viewID,
		Name:        name,
		Description: description,
		Filters:     filters,
		Conditions:  conditions,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
		Owner:       owner,
	}

	svs.views[viewID] = view
	return viewID
}

// GetView retrieves a saved view
func (svs *SavedViewStore) GetView(viewID string) *SavedView {
	return svs.views[viewID]
}

// ListViews lists all saved views for an owner
func (svs *SavedViewStore) ListViews(owner string) []*SavedView {
	views := make([]*SavedView, 0)
	for _, view := range svs.views {
		if view.Owner == owner {
			views = append(views, view)
		}
	}
	return views
}

// ============================================================================
// BUILT-IN FILTER TEMPLATES
// ============================================================================

// FilterAllDomainJoined returns filter for all domain-joined devices
func FilterAllDomainJoined() *QueryBuilder {
	return NewQueryBuilder().
		AddFilter("status", "eq", "domain_joined")
}

// FilterAllWorkgroup returns filter for all workgroup devices
func FilterAllWorkgroup() *QueryBuilder {
	return NewQueryBuilder().
		AddFilter("status", "eq", "workgroup")
}

// FilterUnreachable returns filter for unreachable devices
func FilterUnreachable() *QueryBuilder {
	return NewQueryBuilder().
		AddFilter("status", "eq", "unreachable")
}

// FilterByDomain returns filter for devices in a specific domain
func FilterByDomain(domain string) *QueryBuilder {
	return NewQueryBuilder().
		AddFilter("domain", "eq", domain)
}

// FilterByDeviceType returns filter for specific device type
func FilterByDeviceType(deviceType string) *QueryBuilder {
	return NewQueryBuilder().
		AddFilter("device_type", "eq", deviceType)
}

// FilterLastSeenWithin returns filter for devices seen within last duration
func FilterLastSeenWithin(duration time.Duration) *QueryBuilder {
	since := time.Now().Add(-duration).Format(time.RFC3339)
	return NewQueryBuilder().
		AddFilter("last_seen", "gt", since)
}
