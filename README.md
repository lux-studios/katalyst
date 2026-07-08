## Katalyst (Liquid Breakout fork)
This is a fork of the [katalyst](https://github.com/miukyo/katalyst) UI framework, repurposed as a general instance framework with custom optimizations and special changes.

It is currently used in Liquid Breakout.

See the official [Katalyst documentation](https://katalyst.miukyo.my.id) for more information.

### Differences

* An `Unwrap` function is added to guarantee real instances and state values to pass to the Roblox API.
* All functions have an alternative name following the `lowerCamelCase` naming convention for use in Liquid Breakout.
* Custom optimizations have been made for better performance.
* Default properties have been removed.
* Custom button events (`Draggable`, `OnDrag`, `OnEnter`, etc.) have been removed from `New`.
* Children and Ref properties are changed to special userdatas for future-proofing.
  * Instead of `Children`, use `[katalyst.Children]` or `[Children]`.

These differences, while significant, retain Katalyst's simplicity and minimal lines of code.

### Principle

Katalyst wraps Roblox instances in a proxy so you can:
* Bind properties directly to states.
* React to changes with computed properties.
* Manage children declaratively with a special `Children` key and the `Map` function.
* Bind to events and perform cleanup operations with a special `Ref` key.

Think of it like Roact/Fusion, but lean and without the ceremony.
