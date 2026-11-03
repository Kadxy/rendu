package server

import (
	"encoding/json"
	"net/http"
	"strings"

	sdk "github.com/Kadxy/rendu/internal/schema"
	"github.com/Kadxy/rendu/internal/store"
)

// The schema (docs/PROTOCOL.md, "Schema"): Apple's definitions from the SDK
// the server was built with (package schema), what the phone's HealthKit
// supports (its catalog), and Rendu's object formats (store/kinds.go).

// putCatalog replaces the phone's catalog (store/catalog.go).
func (s *Server) putCatalog(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		s.fail(w, err)
		return
	}
	if !json.Valid(body) {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	n, err := s.store.PutCatalog(r.Context(), body)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"stored": n})
}

type kindSummary struct {
	Kind  string `json:"kind"`
	Read  bool   `json:"read"`
	Write bool   `json:"write"`
	How   string `json:"how"`
}

// typeSummary is a type in the overview.
type typeSummary struct {
	Type        string            `json:"type"`
	Kind        string            `json:"kind"`
	Name        map[string]string `json:"name,omitempty"`
	Unit        string            `json:"unit,omitempty"`
	Aggregation string            `json:"aggregation,omitempty"`
	Share       string            `json:"share,omitempty"`
	PerObject   bool              `json:"perObject,omitempty"`
}

// schemaOverview lists what there is: the kinds, the types (the phone's,
// or the SDK's until the phone uploads its catalog), and the names of the
// enums and metadata keys.
func (s *Server) schemaOverview(w http.ResponseWriter, r *http.Request) {
	catalog, share, err := s.phoneSchema(r)
	if err != nil {
		s.fail(w, err)
		return
	}
	kinds := []kindSummary{}
	for _, k := range store.Kinds() {
		kinds = append(kinds, kindSummary{k.Kind, k.Read, k.Write, k.How})
	}
	types := []typeSummary{}
	if catalog.UpdatedAt != nil {
		for _, e := range catalog.Types {
			types = append(types, typeSummary{Type: e.Type, Kind: e.Kind, Name: e.Name, Unit: e.Unit,
				Aggregation: e.Aggregation, Share: share[e.Type], PerObject: e.PerObject})
		}
	} else {
		for _, id := range sdk.TypeIDs() {
			_, t, _ := sdk.LookupType(id)
			if !t.Deprecated {
				types = append(types, typeSummary{Type: id, Kind: t.Kind, Aggregation: t.Aggregation, Share: share[id]})
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sdk":              map[string]string{"version": sdk.Version()},
		"os":               catalog.OS,
		"catalogUpdatedAt": catalog.UpdatedAt,
		"kinds":            kinds,
		"types":            types,
		"enums":            sdk.EnumNames(),
		"metadataKeys":     sdk.MetadataKeys(),
	})
}

func (s *Server) phoneSchema(r *http.Request) (store.Catalog, map[string]string, error) {
	catalog, err := s.store.Catalog(r.Context())
	if err != nil {
		return catalog, nil, err
	}
	auth, err := s.store.Authorization(r.Context())
	return catalog, auth.Share, err
}

// sdkType is a type's SDK entry with its values' enum inline.
type sdkType struct {
	sdk.Type
	Values *sdk.Enum `json:"values,omitempty"`
}

// schemaType is everything about one type: the phone's entry, the SDK's,
// whether Rendu may write it, its kind's object format, and an example
// object of this type.
func (s *Server) schemaType(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("type")
	noteActivity(r, func(a *store.Activity) { a.Type = clip(name) })
	catalog, share, err := s.phoneSchema(r)
	if err != nil {
		s.fail(w, err)
		return
	}
	id, t, inSDK := sdk.LookupType(name)
	var entry *store.CatalogEntry
	for i, e := range catalog.Types {
		if e.Type == id {
			entry = &catalog.Types[i]
			break
		}
	}
	if !inSDK && entry == nil {
		writeError(w, http.StatusNotFound, "no type "+name+" in the iPhone's catalog or the SDK")
		return
	}

	resp := struct {
		Type    string              `json:"type"`
		Kind    string              `json:"kind"`
		Read    *bool               `json:"read,omitempty"`
		Write   *bool               `json:"write,omitempty"`
		How     string              `json:"how,omitempty"`
		Share   string              `json:"share,omitempty"`
		Catalog *store.CatalogEntry `json:"catalog,omitempty"`
		SDK     *sdkType            `json:"sdk,omitempty"`
		Fields  []store.Field       `json:"fields,omitempty"`
		Example json.RawMessage     `json:"example,omitempty"`
	}{Type: id, Share: share[id], Catalog: entry}

	var hints store.ExampleHints
	if inSDK {
		st := &sdkType{Type: t}
		if e, ok := sdk.LookupEnum(t.Values); ok {
			st.Values = &e
			hints.Value = firstValue(e)
		}
		resp.SDK = st
		resp.Kind = t.Kind
		hints.Unit = noteUnit(t)
		hints.Cumulative = t.Aggregation == "cumulative"
	}
	if entry != nil {
		resp.Kind = entry.Kind
		if entry.Unit != "" {
			hints.Unit = entry.Unit
		}
		if entry.Aggregation != "" {
			hints.Cumulative = entry.Aggregation == "cumulative"
		}
		if v := catalogValue(entry.Raw); v != nil {
			hints.Value = v
		}
	}
	if k, ok := store.LookupKind(store.KindOfType(id)); ok {
		resp.Kind = k.Kind
		resp.Read, resp.Write, resp.How = &k.Read, &k.Write, k.How
		resp.Fields = k.Fields
		resp.Example = k.ExampleFor(id, hints)
	}
	writeJSON(w, http.StatusOK, resp)
}

// noteUnit is the unit in Apple's note on a quantity type ("kg, Discrete
// (Arithmetic)"); none means a count (UVExposure).
func noteUnit(t sdk.Type) string {
	if t.Kind != "quantity" {
		return ""
	}
	unit, _, _ := strings.Cut(t.Note, ",")
	if unit = strings.TrimSpace(unit); unit != "" {
		return unit
	}
	return "count"
}

func firstValue(e sdk.Enum) *int64 {
	for _, c := range e.Cases {
		if !c.Deprecated {
			v := c.Value
			return &v
		}
	}
	return nil
}

// catalogValue is the first of the values the phone lists for a category
// type.
func catalogValue(raw json.RawMessage) *int64 {
	var e struct {
		Values []struct {
			Value *int64 `json:"value"`
		} `json:"values"`
	}
	if json.Unmarshal(raw, &e) != nil || len(e.Values) == 0 {
		return nil
	}
	return e.Values[0].Value
}

func (s *Server) schemaKind(w http.ResponseWriter, r *http.Request) {
	k, ok := store.LookupKind(r.PathValue("kind"))
	if !ok {
		writeError(w, http.StatusNotFound, "no kind "+r.PathValue("kind"))
		return
	}
	writeJSON(w, http.StatusOK, k)
}

func (s *Server) schemaEnum(w http.ResponseWriter, r *http.Request) {
	e, ok := sdk.LookupEnum(r.PathValue("name"))
	if !ok {
		writeError(w, http.StatusNotFound, "no enum "+r.PathValue("name")+" in the SDK")
		return
	}
	writeJSON(w, http.StatusOK, e)
}

func (s *Server) schemaMetadataKey(w http.ResponseWriter, r *http.Request) {
	m, ok := sdk.LookupMetadataKey(r.PathValue("key"))
	if !ok {
		writeError(w, http.StatusNotFound, "no metadata key "+r.PathValue("key")+" in the SDK")
		return
	}
	resp := struct {
		sdk.MetadataKey
		Values *sdk.Enum `json:"values,omitempty"`
	}{MetadataKey: m}
	if e, ok := sdk.LookupEnum(m.Values); ok {
		resp.Values = &e
	}
	writeJSON(w, http.StatusOK, resp)
}
