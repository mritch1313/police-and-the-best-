extends RefCounted
class_name TestCase
## Tiny test framework for the project.
##
## It exists instead of an addon because the project must not depend on external code, and
## because the tests need something an addon cannot give them: they run inside the real engine
## with the real physics, so a test can drive a car for six seconds of simulated time and
## assert what actually happened.
##
## Every test returns a name, a number of checks and a list of failures, so both the local
## runner and the CI smoke report can show the same numbers.

## Human readable suite name, shown in the report.
var suite: String = "unnamed"
## Number of assertions that ran.
var checks: int = 0
## Failures, each with the assertion message.
var failures: Array[String] = []
## Notes the test wants to record in the report (measurements, timings).
var notes: Array[String] = []


func _init() -> void:
	suite = _suite_name()


## Override in every test: the name that appears in the report.
func _suite_name() -> String:
	return "unnamed"


## Override in every test: the actual test body. May `await`.
func run(_tree: SceneTree) -> void:
	pass


# --------------------------------------------------------------------------------------
# assertions
# --------------------------------------------------------------------------------------
func check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


func check_almost(value: float, expected: float, tolerance: float, message: String) -> bool:
	checks += 1
	if absf(value - expected) > tolerance:
		failures.append(
			"%s (got %.4f, expected %.4f +/- %.4f)" % [message, value, expected, tolerance]
		)
		return false
	return true


func check_greater(value: float, minimum: float, message: String) -> bool:
	checks += 1
	if value <= minimum:
		failures.append("%s (got %.4f, expected > %.4f)" % [message, value, minimum])
		return false
	return true


func check_less(value: float, maximum: float, message: String) -> bool:
	checks += 1
	if value >= maximum:
		failures.append("%s (got %.4f, expected < %.4f)" % [message, value, maximum])
		return false
	return true


func check_between(value: float, minimum: float, maximum: float, message: String) -> bool:
	checks += 1
	if value < minimum or value > maximum:
		failures.append("%s (got %.4f, expected %.4f..%.4f)" % [message, value, minimum, maximum])
		return false
	return true


func check_not_null(value: Variant, message: String) -> bool:
	checks += 1
	if value == null:
		failures.append(message)
		return false
	return true


func note(text: String) -> void:
	notes.append(text)


func passed() -> bool:
	return failures.is_empty()


func summary_line() -> String:
	return "[TEST] %s: %d checks, %d failed" % [suite, checks, failures.size()]
