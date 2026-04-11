#pragma once

#include "store/entry.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace syncpss::store {

class PasswordStore {
public:
    PasswordStore(std::filesystem::path store_path, std::string gpg_key_id);

    std::vector<std::string> list_entries() const;
    Entry read_entry(const std::string& name) const;
    std::string read_notes(const std::string& name) const;
    void save_entry(const Entry& entry, bool overwrite) const;
    void delete_entry(const std::string& name) const;
    void delete_tree(const std::string& path) const;
    void delete_notes(const std::string& name, const std::string& username = "") const;
    void initialize_store() const;
    bool has_legacy_plaintext_notes() const;
    std::size_t legacy_plaintext_notes_count() const;
    std::filesystem::path migrate_legacy_plaintext_notes() const;

    std::string generate_password(std::size_t length = 32U) const;
    bool validate_entry_name(const std::string& name) const;
    const std::filesystem::path& path() const noexcept;

private:
    std::filesystem::path store_path_;
    std::string gpg_key_id_;

    Entry parse_entry(const std::string& name, const std::string& raw) const;
    std::string serialize_entry(const Entry& entry) const;
};

}  // namespace syncpss::store
