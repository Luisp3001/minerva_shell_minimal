"""Generación de imágenes con Gemini y guardado privado acotado."""

import base64
import binascii
import datetime
import os
import pathlib
import tempfile
import uuid


MAX_GENERATED_IMAGE_BYTES = 30 * 1024 * 1024


def tool_generate_image(
    prompt: str,
    resolution: str = "1K",
    api_key: str = "",
) -> str:
    try:
        from google import genai
        from google.genai import types
    except ImportError:
        return (
            "Error: la librería 'google-genai' no está instalada. "
            "Ejecuta 'pip install google-genai'."
        )

    api_key = api_key or os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        return "Error: configura la API Key de Gemini en los ajustes."
    if resolution not in {"1K", "2K"}:
        return "Error: resolution debe ser '1K' o '2K'."

    try:
        client = genai.Client(
            api_key=api_key,
            http_options=types.HttpOptions(timeout=120_000),
        )
        interaction = client.interactions.create(
            model="gemini-3.1-flash-image",
            input=prompt,
            response_format={
                "type": "image",
                "mime_type": "image/jpeg",
                "aspect_ratio": "1:1",
                "image_size": resolution,
            },
        )
    except Exception as exc:
        return f"Error al generar la imagen: {type(exc).__name__}"

    encoded = getattr(getattr(interaction, "output_image", None), "data", None)
    if not isinstance(encoded, (str, bytes)) or not encoded:
        return "Error: Gemini no devolvió datos de imagen."
    if len(encoded) > (MAX_GENERATED_IMAGE_BYTES * 4 // 3) + 4:
        return "Error: la imagen generada supera el límite permitido."
    try:
        image_bytes = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError, TypeError):
        return "Error: Gemini devolvió una imagen base64 inválida."
    if (
        len(image_bytes) > MAX_GENERATED_IMAGE_BYTES
        or not image_bytes.startswith(b"\xff\xd8\xff")
    ):
        return "Error: Gemini devolvió una imagen JPEG inválida o demasiado grande."

    picture_dir = pathlib.Path.home() / "Pictures" / "minerva"
    try:
        picture_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        destination = picture_dir / f"gen_{timestamp}_{uuid.uuid4().hex[:8]}.jpg"
        temp_name = ""
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=picture_dir,
                prefix=".minerva-image-",
                delete=False,
            ) as temporary:
                temporary.write(image_bytes)
                temporary.flush()
                temp_name = temporary.name
            os.chmod(temp_name, 0o600)
            os.replace(temp_name, destination)
        finally:
            if temp_name:
                pathlib.Path(temp_name).unlink(missing_ok=True)
    except OSError as exc:
        return f"Error al guardar la imagen: {type(exc).__name__}"

    if resolution == "2K":
        return f"Imagen 2K generada y guardada en {destination}"
    return f"![Imagen Generada]({destination})"
