"""Registro tipado de herramientas y validación de sus argumentos JSON."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


ToolHandler = Callable[[dict, dict], Any]


@dataclass(frozen=True, slots=True)
class ToolSpec:
    name: str
    definition: dict
    handler: ToolHandler | None = None

    @property
    def schema(self) -> dict:
        return self.definition["function"]["parameters"]


class ToolRegistry:
    """Fuente única para descubrir, validar y despachar capacidades."""

    def __init__(self, definitions: list[dict]) -> None:
        self._specs = {
            definition["function"]["name"]: ToolSpec(
                name=definition["function"]["name"],
                definition=definition,
            )
            for definition in definitions
        }

    def register(self, name: str):
        if name not in self._specs:
            raise KeyError(f"No existe definición para la herramienta {name!r}")

        def decorator(handler: ToolHandler):
            current = self._specs[name]
            self._specs[name] = ToolSpec(name, current.definition, handler)
            return handler

        return decorator

    def validate(self, name: str, args: object) -> str | None:
        spec = self._specs.get(name)
        if spec is None:
            return "Herramienta desconocida"
        if not isinstance(args, dict):
            return "Los argumentos deben ser un objeto JSON"

        schema = spec.schema
        properties = schema.get("properties", {})
        unexpected = set(args) - set(properties)
        if unexpected:
            return f"Argumentos no permitidos: {', '.join(sorted(unexpected))}"
        missing = [
            field
            for field in schema.get("required", [])
            if field not in args
        ]
        if missing:
            return f"Faltan argumentos requeridos: {', '.join(missing)}"

        expected_types = {
            "string": str,
            "integer": int,
            "boolean": bool,
            "object": dict,
            "array": list,
        }
        for field, value in args.items():
            rule = properties[field]
            expected = expected_types.get(rule.get("type"))
            if expected is int and isinstance(value, bool):
                return f"El argumento '{field}' debe ser integer"
            if expected is not None and not isinstance(value, expected):
                return f"El argumento '{field}' debe ser {rule.get('type')}"
            if "enum" in rule and value not in rule["enum"]:
                return f"Valor inválido para '{field}'"
            if isinstance(value, int) and not isinstance(value, bool):
                if value < rule.get("minimum", value):
                    return f"El argumento '{field}' es menor que el mínimo"
                if value > rule.get("maximum", value):
                    return f"El argumento '{field}' supera el máximo"
        return None

    def dispatch(self, name: str, args: dict, context: dict):
        error = self.validate(name, args)
        if error:
            return f"Error: {error}"
        spec = self._specs[name]
        if spec.handler is None:
            return f"Error: la herramienta {name!r} no tiene handler"
        return spec.handler(args, context)

    def assert_complete(self) -> None:
        missing = [name for name, spec in self._specs.items() if spec.handler is None]
        if missing:
            names = ", ".join(sorted(missing))
            raise RuntimeError(f"Herramientas sin handler: {names}")
