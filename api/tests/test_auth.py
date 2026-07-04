from uuid import uuid4
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from api.routes import auth as auth_routes
from api.schemas.auth import LoginRequest, SignupRequest
from api.utils.auth import verify_password


@pytest.mark.asyncio
async def test_local_signup_updates_existing_password_and_login_succeeds(
    db_session,
    monkeypatch,
):
    email = f"test-local-auth-{uuid4().hex}@example.com"
    old_password = "old-password-123"
    new_password = "new-password-456"

    user = await db_session.create_user_with_email(
        email=email,
        password_hash=auth_routes.hash_password(old_password),
    )

    monkeypatch.setattr(auth_routes, "AUTH_PROVIDER", "local")
    monkeypatch.setattr(
        auth_routes,
        "create_user_configuration_with_mps_key",
        AsyncMock(return_value=None),
    )
    monkeypatch.setattr(auth_routes, "capture_event", lambda *args, **kwargs: None)
    monkeypatch.setattr(auth_routes, "create_jwt_token", lambda *args, **kwargs: "token")

    signup_response = await auth_routes.signup(
        SignupRequest(email=email, password=new_password)
    )

    assert signup_response.token == "token"
    assert signup_response.user.email == email
    assert signup_response.user.id == user.id

    updated_user = await db_session.get_user_by_email(email)
    assert updated_user is not None
    assert verify_password(new_password, updated_user.password_hash)
    assert not verify_password(old_password, updated_user.password_hash)

    login_response = await auth_routes.login(
        LoginRequest(email=email, password=new_password)
    )

    assert login_response.token == "token"
    assert login_response.user.email == email
    assert login_response.user.id == user.id