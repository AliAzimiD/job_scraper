def test_imports():
    """Test that important modules can be imported."""
    try:
        from src.scraper import JobScraper
        from src.db_manager import DatabaseManager
        from src.config_manager import ConfigManager
        assert True
    except ImportError as e:
        assert False, f"Import error: {e}"

def test_configuration():
    """Test that configuration can be loaded."""
    from src.config_manager import ConfigManager
    config = ConfigManager("config/api_config.yaml")
    assert config.api_config is not None
    assert config.request_config is not None
    assert config.scraper_config is not None
