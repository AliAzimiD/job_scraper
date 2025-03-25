from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, Dict, Any, List, Union
import json


@dataclass
class Job:
    """
    Represents a job posting with all related information.
    Uses a dataclass for better type safety and data validation.
    """
    id: str
    title: str
    company_name_en: str = ""
    company_name_fa: str = ""
    activation_time: Optional[datetime] = None
    url: str = ""
    locations: Optional[Union[str, List[Dict[str, Any]]]] = None
    salary: str = ""
    raw_data: Optional[Dict[str, Any]] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None
    
    # Derived columns that are calculated from raw_data
    primary_city: str = ""
    work_type: str = ""
    category: str = ""
    sub_cat: str = ""
    parent_cat: str = ""
    jobBoard_titleEn: str = ""
    jobBoard_titleFa: str = ""
    
    # Tag indicators (one-hot encoded)
    tag_no_experience: int = 0
    tag_remote: int = 0
    tag_part_time: int = 0
    tag_internship: int = 0
    tag_military_exemption: int = 0
    
    def __post_init__(self):
        """Process after initialization to handle conversions"""
        # Convert string locations to dictionary if needed
        if isinstance(self.locations, str):
            try:
                self.locations = json.loads(self.locations)
            except (json.JSONDecodeError, TypeError):
                self.locations = None
        
        # Convert string raw_data to dictionary if needed
        if isinstance(self.raw_data, str):
            try:
                self.raw_data = json.loads(self.raw_data)
            except (json.JSONDecodeError, TypeError):
                self.raw_data = {}
        
        # Ensure datetime objects for dates
        if self.activation_time and isinstance(self.activation_time, str):
            try:
                self.activation_time = datetime.fromisoformat(self.activation_time.replace('Z', '+00:00'))
            except (ValueError, TypeError):
                try:
                    self.activation_time = datetime.strptime(self.activation_time, "%Y-%m-%d %H:%M:%S")
                except (ValueError, TypeError):
                    self.activation_time = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert job to dictionary for serialization"""
        result = {
            'id': self.id,
            'title': self.title,
            'company_name_en': self.company_name_en,
            'company_name_fa': self.company_name_fa,
            'activation_time': self.activation_time.isoformat() if self.activation_time else None,
            'url': self.url,
            'primary_city': self.primary_city,
            'category': self.category,
            'is_remote': bool(self.tag_remote),
            'is_part_time': bool(self.tag_part_time),
            'is_internship': bool(self.tag_internship),
            'requires_experience': not bool(self.tag_no_experience)
        }
        
        # Add raw data only if explicitly requested to avoid large responses
        # result['raw_data'] = self.raw_data
        
        return result
    
    @classmethod
    def from_api_data(cls, job_data: Dict[str, Any]) -> 'Job':
        """
        Create a Job instance from API data.
        
        Args:
            job_data: Raw job data from the API
            
        Returns:
            Initialized Job instance
        """
        job_id = job_data.get('id', '')
        
        # Extract company information
        company_info = job_data.get('company', {})
        company_name_en = company_info.get('titleEn', '')
        company_name_fa = company_info.get('titleFa', '')
        
        # If company info is empty, try using companyDetailsSummary
        if not company_name_en and not company_name_fa:
            company_details = job_data.get('companyDetailsSummary', {})
            if company_details and company_details.get('name'):
                company_name_en = company_details.get('name', {}).get('titleEn', '')
                company_name_fa = company_details.get('name', {}).get('titleFa', '')
        
        # Get activation time
        activation_time = None
        activation_time_data = job_data.get('activationTime', {})
        if activation_time_data and 'date' in activation_time_data:
            activation_time = activation_time_data.get('date')
        
        # Create and return job instance
        return cls(
            id=str(job_id),
            title=job_data.get('title', ''),
            company_name_en=company_name_en,
            company_name_fa=company_name_fa,
            activation_time=activation_time,
            url=job_data.get('url', ''),
            locations=job_data.get('locations', []),
            salary=job_data.get('salary', ''),
            raw_data=job_data,
            created_at=datetime.now(),
            updated_at=datetime.now()
        ) 