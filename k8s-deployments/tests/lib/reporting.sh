#!/bin/bash
# Test reporting functions

# Print test summary
print_test_summary() {
    local duration=$1

    echo
    echo "========================================"
    echo "         TEST RESULTS SUMMARY"
    echo "========================================"
    echo
    echo -e "Total Tests:   ${BLUE}${TESTS_TOTAL}${NC}"
    echo -e "Passed:        ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed:        ${RED}${TESTS_FAILED}${NC}"
    echo -e "Skipped:       ${YELLOW}${TESTS_SKIPPED}${NC}"
    echo
    echo -e "Duration:      ${duration}"
    echo
    echo "========================================"
    echo

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}✗ TESTS FAILED${NC}"
        return 1
    elif [ "$TESTS_PASSED" -eq 0 ]; then
        echo -e "${YELLOW}⚠ NO TESTS PASSED${NC}"
        return 1
    else
        echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
        return 0
    fi
}

# Generate JUnit XML report
generate_junit_xml() {
    local output_file=$1
    local duration=$2

    log_info "Generating JUnit XML report: $output_file"

    cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Pipeline Regression Tests"
             tests="${TESTS_TOTAL}"
             failures="${TESTS_FAILED}"
             skipped="${TESTS_SKIPPED}"
             time="${duration}">
    <!-- Test results would be appended here by individual test scripts -->
  </testsuite>
</testsuites>
EOF

    log_pass "JUnit XML report generated"
}

# Generate HTML report
generate_html_report() {
    local output_file=$1
    local duration=$2

    log_info "Generating HTML report: $output_file"

    local pass_rate=0
    if [ "$TESTS_TOTAL" -gt 0 ]; then
        pass_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    fi

    local status_color="red"
    if [ "$TESTS_FAILED" -eq 0 ] && [ "$TESTS_PASSED" -gt 0 ]; then
        status_color="green"
    fi

    cat > "$output_file" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Pipeline Regression Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 3px solid #4CAF50; padding-bottom: 10px; }
        .summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin: 30px 0; }
        .metric { background: #f9f9f9; padding: 20px; border-radius: 4px; text-align: center; }
        .metric-value { font-size: 36px; font-weight: bold; margin: 10px 0; }
        .metric-label { color: #666; text-transform: uppercase; font-size: 12px; }
        .passed { color: #4CAF50; }
        .failed { color: #f44336; }
        .skipped { color: #ff9800; }
        .total { color: #2196F3; }
        .status { padding: 20px; border-radius: 4px; text-align: center; font-size: 24px; font-weight: bold; margin: 20px 0; }
        .status.success { background: #4CAF50; color: white; }
        .status.failure { background: #f44336; color: white; }
        .progress-bar { width: 100%; height: 30px; background: #e0e0e0; border-radius: 15px; overflow: hidden; }
        .progress-fill { height: 100%; background: linear-gradient(90deg, #4CAF50, #8BC34A); transition: width 0.3s; }
        .metadata { margin: 20px 0; padding: 15px; background: #f9f9f9; border-left: 4px solid #2196F3; }
        .metadata dt { font-weight: bold; color: #666; }
        .metadata dd { margin: 5px 0 15px 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Pipeline Regression Test Report</h1>

        <div class="status ${status_color}">
            $([ "$TESTS_FAILED" -eq 0 ] && echo "✓ ALL TESTS PASSED" || echo "✗ TESTS FAILED")
        </div>

        <div class="summary">
            <div class="metric">
                <div class="metric-value total">${TESTS_TOTAL}</div>
                <div class="metric-label">Total Tests</div>
            </div>
            <div class="metric">
                <div class="metric-value passed">${TESTS_PASSED}</div>
                <div class="metric-label">Passed</div>
            </div>
            <div class="metric">
                <div class="metric-value failed">${TESTS_FAILED}</div>
                <div class="metric-label">Failed</div>
            </div>
            <div class="metric">
                <div class="metric-value skipped">${TESTS_SKIPPED}</div>
                <div class="metric-label">Skipped</div>
            </div>
        </div>

        <div class="progress-bar">
            <div class="progress-fill" style="width: ${pass_rate}%"></div>
        </div>
        <p style="text-align: center; color: #666; margin-top: 10px;">Pass Rate: ${pass_rate}%</p>

        <dl class="metadata">
            <dt>Test Duration:</dt>
            <dd>${duration}</dd>

            <dt>Timestamp:</dt>
            <dd>$(date)</dd>

            <dt>Test Namespace:</dt>
            <dd>${TEST_NAMESPACE:-N/A}</dd>

            <dt>Git Commit:</dt>
            <dd>$(git rev-parse HEAD 2>/dev/null || echo "N/A")</dd>
        </dl>
    </div>
</body>
</html>
EOF

    log_pass "HTML report generated"
}

# Generate JSON report
generate_json_report() {
    local output_file=$1
    local duration=$2

    log_info "Generating JSON report: $output_file"

    cat > "$output_file" <<EOF
{
  "summary": {
    "total": ${TESTS_TOTAL},
    "passed": ${TESTS_PASSED},
    "failed": ${TESTS_FAILED},
    "skipped": ${TESTS_SKIPPED},
    "duration": "${duration}",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "metadata": {
    "namespace": "${TEST_NAMESPACE:-}",
    "commit": "$(git rev-parse HEAD 2>/dev/null || echo "unknown")",
    "branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  }
}
EOF

    log_pass "JSON report generated"
}

# Generate all reports
generate_reports() {
    local duration=$1
    local results_dir
    results_dir=$(get_results_dir)

    if [ -n "${JUNIT_OUTPUT:-}" ]; then
        generate_junit_xml "$JUNIT_OUTPUT" "$duration"
    fi

    if [ -n "${HTML_OUTPUT:-}" ]; then
        generate_html_report "$HTML_OUTPUT" "$duration"
    fi

    if [ -n "${JSON_OUTPUT:-}" ]; then
        generate_json_report "$JSON_OUTPUT" "$duration"
    fi
}
