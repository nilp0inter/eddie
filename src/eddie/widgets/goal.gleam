/// Goal widget — keeps the agent focused on a specific objective.
///
/// Protocol-free: set_goal and clear_goal work without an active task.
/// Both the LLM and the browser can set/clear the goal.
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/set
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

import eddie/cmd.{type Cmd, type Initiator, LLM, UI}
import eddie/message.{type Message}
import eddie/tool.{type ToolDefinition}
import eddie/widget.{type WidgetHandle}

// ============================================================================
// Model
// ============================================================================

pub type GoalModel {
  GoalModel(text: Option(String))
}

// ============================================================================
// Messages
// ============================================================================

pub type GoalMsg {
  SetGoal(goal: String, initiator: Initiator)
  ClearGoal(initiator: Initiator)
}

// ============================================================================
// Update
// ============================================================================

fn update(_model: GoalModel, msg: GoalMsg) -> #(GoalModel, Cmd(GoalMsg)) {
  case msg {
    SetGoal(goal, initiator) -> #(
      GoalModel(text: Some(goal)),
      cmd.for_initiator(initiator: initiator, text: "Goal set: " <> goal),
    )
    ClearGoal(initiator) -> #(
      GoalModel(text: None),
      cmd.for_initiator(initiator: initiator, text: "Goal cleared"),
    )
  }
}

// ============================================================================
// Views
// ============================================================================

fn view_messages(model: GoalModel) -> List(Message) {
  let text = case model.text {
    None -> "## Goal\nNo goal set"
    Some(goal) -> "## Goal\n" <> goal
  }
  [message.Request(parts: [message.UserPart(text)])]
}

fn view_tools(_model: GoalModel) -> List(ToolDefinition) {
  let assert Ok(set_goal_tool) =
    tool.new(
      name: "set_goal",
      description: "Set the overall goal for the conversation. Use once at the start to establish the objective. Do not change it mid-conversation.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "goal",
              json.object([
                #("type", json.string("string")),
                #("description", json.string("The goal text.")),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["goal"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let assert Ok(clear_goal_tool) =
    tool.new(
      name: "clear_goal",
      description: "Clear the goal only after it has been fully fulfilled.",
      parameters_json: json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  [set_goal_tool, clear_goal_tool]
}

fn view_html(model: GoalModel) -> Element(Nil) {
  let content = case model.text {
    None -> html.em([], [html.text("No goal set")])
    Some(goal) -> html.p([], [html.text(goal)])
  }
  html.div([], [
    html.h3([], [html.text("Goal")]),
    content,
    html.input([
      attribute.id("goal-input"),
      attribute.attribute("placeholder", "Set a goal..."),
      attribute.attribute(
        "onkeydown",
        "if(event.key==='Enter'){sendWidgetEvent('set_goal',{goal:this.value});this.value='';}",
      ),
    ]),
    html.button(
      [
        attribute.attribute(
          "onclick",
          "sendWidgetEvent('set_goal', {goal: document.getElementById('goal-input').value})",
        ),
      ],
      [html.text("Set")],
    ),
    html.button(
      [
        attribute.attribute("onclick", "sendWidgetEvent('clear_goal', {})"),
      ],
      [html.text("Clear")],
    ),
  ])
}

// ============================================================================
// Anticorruption layers
// ============================================================================

fn from_llm(
  _model: GoalModel,
  tool_name: String,
  args: Dynamic,
) -> Result(GoalMsg, String) {
  case tool_name {
    "set_goal" -> {
      let goal_decoder = decode.at(["goal"], decode.string)
      case decode.run(args, goal_decoder) {
        Ok(goal) -> Ok(SetGoal(goal: goal, initiator: LLM))
        Error(_) -> Error("set_goal: missing or invalid 'goal' field")
      }
    }
    "clear_goal" -> Ok(ClearGoal(initiator: LLM))
    _ -> Error("Goal: unknown tool '" <> tool_name <> "'")
  }
}

fn from_ui(
  _model: GoalModel,
  event_name: String,
  args: Dynamic,
) -> Option(GoalMsg) {
  case event_name {
    "set_goal" -> {
      let goal_decoder = decode.at(["goal"], decode.string)
      case decode.run(args, goal_decoder) {
        Ok(goal) -> Some(SetGoal(goal: goal, initiator: UI))
        Error(_) -> None
      }
    }
    "clear_goal" -> Some(ClearGoal(initiator: UI))
    _ -> None
  }
}

// ============================================================================
// Factory
// ============================================================================

/// Create a Goal widget handle with the given initial text.
pub fn create(text text: Option(String)) -> WidgetHandle {
  widget.create(widget.WidgetConfig(
    id: "goal",
    model: GoalModel(text: text),
    update: update,
    view_messages: view_messages,
    view_tools: view_tools,
    view_html: view_html,
    from_llm: from_llm,
    from_ui: from_ui,
    frontend_tools: set.from_list(["set_goal", "clear_goal"]),
    protocol_free_tools: set.from_list(["set_goal", "clear_goal"]),
  ))
}

/// Create a Goal widget handle with no initial goal.
pub fn create_default() -> WidgetHandle {
  create(text: None)
}
