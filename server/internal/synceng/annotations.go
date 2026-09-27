package synceng

// bindAnnotations preserves which PDF the coordinates describe. Replacing a PDF
// never silently reattaches coordinates from the prior file to the new file.
func bindAnnotations(snapshot map[string]any, fallbackPDF any) {
	if snapshot["kind"] != "pdf" {
		return
	}
	current, _ := snapshot["pdfBlobId"].(string)
	fallback, _ := fallbackPDF.(string)
	if fallback == "" {
		fallback = current
	}
	annotations, ok := snapshot["annotations"].([]any)
	if !ok {
		return
	}
	bound := make([]any, 0, len(annotations))
	for _, raw := range annotations {
		original, ok := raw.(map[string]any)
		if !ok {
			bound = append(bound, raw)
			continue
		}
		annotation := make(map[string]any, len(original)+2)
		for key, value := range original {
			annotation[key] = value
		}
		pdf, _ := annotation["pdfBlobId"].(string)
		if pdf == "" {
			pdf = fallback
			annotation["pdfBlobId"] = pdf
		}
		if pdf != current {
			annotation["placementState"] = "needs_review"
		} else if annotation["placementState"] == nil || annotation["placementState"] == "" {
			annotation["placementState"] = "attached"
		}
		bound = append(bound, annotation)
	}
	snapshot["annotations"] = bound
}
