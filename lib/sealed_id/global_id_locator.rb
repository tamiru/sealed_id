module SealedId
  # GlobalID stores the raw primary key and hands it to +find+ as a string, so ActiveJob arguments and signed ids would
  # otherwise be refused as invalid tokens. Those strings come from the application, not from a URL.
  module GlobalIdLocator
    def locate(*args)
      SealedId.with_raw_ids { super }
    end

    def locate_many(*args)
      SealedId.with_raw_ids { super }
    end
  end
end
